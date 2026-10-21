import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

import 'close_password.dart';
import 'printer_setup.dart';
import 'wifi_setup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const options = WindowOptions(
    size: Size(480, 640),
    minimumSize: Size(420, 560),
    center: true,
    title: 'Zebra Printer',
  );
  windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });

  runApp(const ZebraPrinterApp());
}

class ZebraPrinterApp extends StatelessWidget {
  const ZebraPrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Zebra Printer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F4B3A),
        ).copyWith(
          primary: const Color(0xFF1A1A1A),
          onPrimary: Colors.white,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF1A1A1A),
            foregroundColor: Colors.white,
            disabledBackgroundColor: const Color(0xFF1A1A1A).withValues(alpha: 0.38),
            disabledForegroundColor: Colors.white.withValues(alpha: 0.7),
          ),
        ),
        useMaterial3: true,
      ),
      home: const PrinterHome(),
    );
  }
}

class PrinterHome extends StatefulWidget {
  const PrinterHome({super.key});

  @override
  State<PrinterHome> createState() => _PrinterHomeState();
}

class _PrinterHomeState extends State<PrinterHome>
    with WindowListener, TrayListener {
  List<ZebraDiscoveredPrinter> _printers = const [];
  String? _selected;
  String _status = 'Looking for the printer...';
  String? _result;
  bool _busy = false;
  bool _printing = false;
  bool _askingPassword = false;
  bool _watching = false;
  bool _settingUp = false;
  bool _setupPaused = false;
  bool _restarting = false;
  String _password = kDefaultClosePassword;
  Timer? _timer;
  final _ssid = TextEditingController();
  final _wifiPassword = TextEditingController();
  List<String> _networks = const [];
  String _pcSsid = '';
  bool _loadingWifi = false;
  bool _wifiBusy = false;
  bool _showPassword = false;
  String? _wifiNote;
  PrinterLink _usbLink = PrinterLink.unplugged;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _start();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ssid.dispose();
    _wifiPassword.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    super.dispose();
  }

  Future<void> _start() async {
    await windowManager.setPreventClose(true);
    final password = await loadClosePassword();
    if (mounted) setState(() => _password = password);
    await _setupTray();
    await _enableLoginStart();
    await _watch();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) => _watch());
  }

  Future<void> _setupTray() async {
    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip('Zebra Printer');
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Open'),
          MenuItem(key: 'refresh', label: 'Find printers'),
          MenuItem.separator(),
          MenuItem(key: 'exit', label: 'Exit'),
        ],
      ),
    );
  }

  Future<void> _enableLoginStart() async {
    try {
      launchAtStartup.setup(
        appName: 'Zebra Printer',
        appPath: Platform.resolvedExecutable,
      );
      await launchAtStartup.enable();
    } catch (error) {
      debugPrint('Login start was not set: $error');
    }
  }

  Future<void> _watch() async {
    if (_watching || _printing || _settingUp || _restarting) return;
    _watching = true;
    try {
      await _refresh();
      if (!mounted) return;
      final machine = await readPrinterMachine();
      if (!mounted) return;
      if (machine == null) {
        setState(() => _status = 'Checking whether the printer is plugged in...');
        return;
      }
      final usbReady = _showMachine(machine);
      if (usbReady || !machine.usbConnected || machine.queueReady || _setupPaused) {
        return;
      }
      await _prepare();
    } finally {
      _watching = false;
    }
  }

  /// Applies the live USB check. A Windows printer queue is shown as ready
  /// only while the Zebra is plugged in and Windows reports it can print.
  bool _showMachine(PrinterMachine machine) {
    final link = printerLinkFrom(machine);
    final printers = <ZebraDiscoveredPrinter>[
      for (final printer in _printers)
        if (printer.transport != ZebraTransport.usb || machine.usbConnected)
          printer,
    ];
    final hasUsb = printers.any((printer) => printer.transport == ZebraTransport.usb);
    if (link.showPrinter && machine.queueName.isNotEmpty && !hasUsb) {
      printers.insert(0, _queuePrinter(machine));
    }
    final bluetoothReady = printers.any(
      (printer) => printer.transport == ZebraTransport.bluetooth,
    );
    final status = link.canPrint || machine.usbConnected || machine.queueName.isNotEmpty
        ? link.message
        : (bluetoothReady ? 'Printer is ready.' : link.message);
    setState(() {
      _printers = printers;
      _selected = _keepSelection(printers);
      _usbLink = link;
      _status = status;
    });
    if (link.cableConnected) _loadWifi();
    return link.canPrint;
  }

  ZebraDiscoveredPrinter _queuePrinter(PrinterMachine machine) {
    final name = machine.queueName.isEmpty ? machine.deviceName : machine.queueName;
    return ZebraDiscoveredPrinter(
      name: name,
      address: machine.queueName.isEmpty ? name : machine.queueName,
      transport: ZebraTransport.usb,
      port: 0,
    );
  }

  Future<void> _prepare() async {
    _settingUp = true;
    if (mounted) {
      setState(() {
        _status = 'Setting up the printer. If Windows asks, press Yes.';
      });
    }
    final report = await preparePrinter();
    _settingUp = false;
    if (!mounted) return;
    switch (report.outcome) {
      case SetupOutcome.ready:
        _setupPaused = false;
        await _refresh();
        if (!mounted) return;
        final machine = await readPrinterMachine();
        if (!mounted || machine == null) return;
        _showMachine(machine);
      case SetupOutcome.needReboot:
        _setupPaused = true;
        setState(() {
          _status = 'Restart the computer. Leave the printer plugged in.';
        });
      case SetupOutcome.cancelled:
        _setupPaused = true;
        setState(() {
          _status = 'Windows needs permission to set up the printer.';
        });
      case SetupOutcome.needInstaller:
        _setupPaused = true;
        setState(() {
          _status = 'This computer is missing the printer program.';
        });
      case SetupOutcome.noDevice:
        setState(() => _status = 'Plug the printer into the USB cable.');
      case SetupOutcome.failed:
        _setupPaused = true;
        setState(() {
          _status = 'The printer could not be set up. Press Try again.';
        });
    }
  }

  Future<void> _restartComputer() async {
    if (_restarting) return;
    setState(() {
      _restarting = true;
      _status = 'The computer will restart in a few seconds.';
    });
    await restartComputerForPrinter();
  }

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() => _busy = true);
    final printers = <ZebraDiscoveredPrinter>[];
    try {
      try {
        printers.addAll(await ZebraSdk.discoverBluetooth());
      } on PlatformException {
        // No Bluetooth radio is normal. USB setup continues.
      }
      try {
        printers.addAll(await ZebraSdk.discoverUsb());
      } on PlatformException {
        // The USB queue may still be created on the next pass.
      }
      if (!mounted) return;
      setState(() {
        _printers = printers;
        _selected = _keepSelection(printers);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _printers = const [];
        _selected = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _keepSelection(List<ZebraDiscoveredPrinter> printers) {
    for (final printer in printers) {
      if (_key(printer) == _selected) return _selected;
    }
    if (printers.isEmpty) return null;
    return _key(printers.first);
  }

  String _key(ZebraDiscoveredPrinter printer) {
    return '${printer.transport.name}|${printer.address}';
  }

  ZebraDiscoveredPrinter? get _current {
    for (final printer in _printers) {
      if (_key(printer) == _selected) return printer;
    }
    return null;
  }

  Future<void> _loadWifi({bool fill = false}) async {
    if (_loadingWifi && !fill) return;
    _loadingWifi = true;
    final scan = await readWifiNetworks();
    _loadingWifi = false;
    if (!mounted) return;
    setState(() {
      _networks = scan.networks;
      _pcSsid = scan.current;
      if ((fill || _ssid.text.isEmpty) && scan.current.isNotEmpty) {
        _ssid.text = scan.current;
        _wifiPassword.text = scan.password;
      }
    });
  }

  Future<void> _useComputerWifi() async {
    await _loadWifi(fill: true);
    if (!mounted) return;
    setState(() {
      _wifiNote = _pcSsid.isEmpty
          ? 'This computer is not on Wi-Fi. Type the network name and password.'
          : (_wifiPassword.text.isEmpty
                ? 'Type the password for this network.'
                : 'Using $_pcSsid.');
    });
  }

  Future<void> _connectWifi() async {
    final printer = _current;
    if (printer == null || _wifiBusy) return;
    setState(() {
      _wifiBusy = true;
      _wifiNote = 'Sending the Wi-Fi settings over USB...';
    });
    try {
      final message = await sendPrinterWifi(
        printer: printer,
        ssid: _ssid.text,
        password: _wifiPassword.text,
      );
      if (!mounted) return;
      setState(() => _wifiNote = message);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _wifiNote =
            'Could not send the Wi-Fi settings. Keep the USB cable connected.';
      });
    } finally {
      if (mounted) setState(() => _wifiBusy = false);
    }
  }

  Future<void> _testPrint() async {
    final printer = _current;
    if (printer == null || _printing) return;
    setState(() {
      _printing = true;
      _result = null;
    });
    final label = _testLabel(printer);
    try {
      await ZebraSdk.printZpl(
        label,
        address: printer.address,
        transport: printer.transport,
        port: printer.port,
      );
      if (!mounted) return;
      setState(() => _result = 'Test label sent.');
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() => _result = error.message ?? 'Test print failed.');
    } catch (error) {
      if (!mounted) return;
      setState(() => _result = '$error');
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  String _testLabel(ZebraDiscoveredPrinter printer) {
    final name = _zplText(printer.name.isEmpty ? 'Zebra' : printer.name);
    final where = printer.transport == ZebraTransport.usb ? 'USB' : 'Bluetooth';
    final address = _zplText(printer.address);
    return '^XA'
        '^PW576'
        '^LL220'
        '^FO30,36^A0N,40,40^FDZebra test^FS'
        '^FO30,96^A0N,28,28^FD$where  $name^FS'
        '^FO30,146^A0N,24,24^FD$address^FS'
        '^XZ';
  }

  bool get _canPrint {
    final printer = _current;
    if (printer == null || _printing) return false;
    if (printer.transport == ZebraTransport.bluetooth) return true;
    return _usbLink.canPrint;
  }

  Widget _printerTile(int index) {
    final item = _printers[index];
    final selected = _key(item) == _selected;
    final usb = item.transport == ZebraTransport.usb;
    final ready = !usb || _usbLink.canPrint;
    return Material(
      color: selected && ready
          ? Theme.of(context).colorScheme.secondaryContainer
          : Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        selected: selected && ready,
        leading: Icon(usb ? Icons.usb : Icons.bluetooth),
        title: Text(item.name.isEmpty ? item.address : item.name),
        subtitle: Text(usb ? _usbLink.detail : item.address),
        trailing: Text(usb ? _usbLink.label : 'Bluetooth'),
        onTap: () => setState(() => _selected = _key(item)),
      ),
    );
  }

  Widget _wifiForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 8),
        Text('Printer Wi-Fi', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 4),
        const Text(
          'The cable sends the network to the printer. The printer must have Wi-Fi.',
        ),
        if (_pcSsid.isNotEmpty) ...[
          const SizedBox(height: 8),
          OutlinedButton(
            onPressed: _wifiBusy ? null : _useComputerWifi,
            child: const Text("Use this computer's Wi-Fi"),
          ),
        ],
        if (_networks.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: ValueKey(
              _networks.contains(_ssid.text) ? _ssid.text : '',
            ),
            initialValue: _networks.contains(_ssid.text) ? _ssid.text : null,
            decoration: const InputDecoration(labelText: 'Choose a network'),
            items: [
              for (final name in _networks)
                DropdownMenuItem(value: name, child: Text(name)),
            ],
            onChanged: _wifiBusy
                ? null
                : (value) {
                    if (value == null) return;
                    setState(() {
                      _ssid.text = value;
                      if (value != _pcSsid) _wifiPassword.text = '';
                    });
                  },
          ),
        ],
        const SizedBox(height: 8),
        TextField(
          controller: _ssid,
          enabled: !_wifiBusy,
          decoration: const InputDecoration(labelText: 'Wi-Fi name'),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _wifiPassword,
          enabled: !_wifiBusy,
          obscureText: !_showPassword,
          decoration: InputDecoration(
            labelText: 'Password',
            helperText: 'Leave empty only if the network has no password.',
            suffixIcon: IconButton(
              onPressed: () => setState(() => _showPassword = !_showPassword),
              icon: Icon(_showPassword ? Icons.visibility_off : Icons.visibility),
              tooltip: _showPassword ? 'Hide password' : 'Show password',
            ),
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _wifiBusy ? null : _connectWifi,
          child: Text(_wifiBusy ? 'Sending...' : 'Connect printer'),
        ),
        if (_wifiNote != null) ...[
          const SizedBox(height: 8),
          Text(_wifiNote!),
        ],
      ],
    );
  }

  String _zplText(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9 :.-]'), ' ');
  }

  Future<void> _showWindow() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> _exit() async {
    if (_askingPassword || !mounted) return;
    _askingPassword = true;
    try {
      final password = await loadClosePassword(fallback: _password);
      if (mounted) setState(() => _password = password);
      if (!mounted) return;
      final allowed = await showClosePasswordDialog(context, password);
      if (!allowed || !mounted) return;
      await windowManager.setPreventClose(false);
      await windowManager.destroy();
    } finally {
      _askingPassword = false;
    }
  }

  @override
  void onWindowClose() {
    _exit();
  }

  @override
  void onWindowMinimize() {
    windowManager.hide();
  }

  @override
  void onTrayIconMouseDown() {
    _showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _showWindow();
      case 'refresh':
        _showWindow();
        _setupPaused = false;
        _watch();
      case 'exit':
        _showWindow();
        _exit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final printer = _current;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 72,
        title: const _BrandLockup(),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: ListView(
                children: [
                  for (var index = 0; index < _printers.length; index++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _printerTile(index),
                    ),
                  if (printer != null &&
                      printer.transport == ZebraTransport.usb &&
                      _usbLink.cableConnected)
                    _wifiForm(),
                ],
              ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 12),
              Text(_result!),
            ],
            const SizedBox(height: 16),
            if (_status.startsWith('Restart the computer')) ...[
              FilledButton(
                onPressed: _restarting ? null : _restartComputer,
                child: const Text('Restart computer'),
              ),
              const SizedBox(height: 8),
            ],
            if (_status.startsWith('Windows needs permission') ||
                _status.startsWith('The printer could not')) ...[
              FilledButton(
                onPressed: _settingUp
                    ? null
                    : () {
                        _setupPaused = false;
                        _watch();
                      },
                child: const Text('Try again'),
              ),
              const SizedBox(height: 8),
            ],
            FilledButton(
              onPressed: _canPrint ? _testPrint : null,
              child: Text(_printing ? 'Printing...' : 'Test print'),
            ),
            const SizedBox(height: 8),
            Text(
              'Leave this window open. It keeps working when minimized.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _BrandLockup extends StatelessWidget {
  const _BrandLockup();

  @override
  Widget build(BuildContext context) {
    final title = Theme.of(context).textTheme.titleMedium;
    final company = Theme.of(context).textTheme.labelLarge?.copyWith(
      letterSpacing: 0.2,
    );
    return Row(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset(
            'assets/app_icon.png',
            width: 52,
            height: 52,
            filterQuality: FilterQuality.high,
          ),
        ),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Zebra Printer', style: title),
            Text('Go& Company', style: company),
          ],
        ),
      ],
    );
  }
}

Future<bool> showClosePasswordDialog(BuildContext context, String expected) {
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _ClosePasswordDialog(expected: expected),
  ).then((value) => value ?? false);
}

class _ClosePasswordDialog extends StatefulWidget {
  const _ClosePasswordDialog({required this.expected});

  final String expected;

  @override
  State<_ClosePasswordDialog> createState() => _ClosePasswordDialogState();
}

class _ClosePasswordDialogState extends State<_ClosePasswordDialog> {
  final _controller = TextEditingController();
  var _wrong = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    if (_controller.text.trim() != widget.expected) {
      setState(() => _wrong = true);
      return;
    }
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Close Zebra Printer'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Enter the password to quit. The printer check stops when this app closes.',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            obscureText: true,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _wrong ? 'Wrong password' : null,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Stay open'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Close')),
      ],
    );
  }
}
