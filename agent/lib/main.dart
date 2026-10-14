import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

import 'close_password.dart';

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
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF1F4B3A)),
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
  String _status = 'Looking for a printer...';
  String? _result;
  bool _busy = false;
  bool _printing = false;
  bool _askingPassword = false;
  String _password = kDefaultClosePassword;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    trayManager.addListener(this);
    _start();
  }

  @override
  void dispose() {
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
    await _refresh();
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

  Future<void> _refresh() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Looking for a printer...';
      _result = null;
    });
    try {
      final found = await Future.wait([
        ZebraSdk.discoverBluetooth(),
        ZebraSdk.discoverUsb(),
      ]);
      final printers = [...found[0], ...found[1]];
      if (!mounted) return;
      setState(() {
        _printers = printers;
        _selected = _keepSelection(printers);
        _status = printers.isEmpty
            ? 'No printer found. Plug in USB, or pair the Zebra over Bluetooth.'
            : '${printers.length} printer${printers.length == 1 ? '' : 's'} found.';
      });
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _printers = const [];
        _selected = null;
        _status = error.message ?? 'Could not look for printers.';
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _printers = const [];
        _selected = null;
        _status = '$error';
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
        _refresh();
      case 'exit':
        _showWindow();
        _exit();
    }
  }

  @override
  Widget build(BuildContext context) {
    final printer = _current;
    return Scaffold(
      appBar: AppBar(title: const Text('Zebra Printer')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            Expanded(
              child: _printers.isEmpty
                  ? const _EmptyPrinters()
                  : ListView.separated(
                      itemCount: _printers.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final item = _printers[index];
                        final selected = _key(item) == _selected;
                        final usb = item.transport == ZebraTransport.usb;
                        return Material(
                          color: selected
                              ? Theme.of(context).colorScheme.secondaryContainer
                              : Theme.of(
                                  context,
                                ).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(12),
                          child: ListTile(
                            selected: selected,
                            leading: Icon(usb ? Icons.usb : Icons.bluetooth),
                            title: Text(
                              item.name.isEmpty ? item.address : item.name,
                            ),
                            subtitle: Text(item.address),
                            trailing: Text(usb ? 'USB' : 'Bluetooth'),
                            onTap: () => setState(() => _selected = _key(item)),
                          ),
                        );
                      },
                    ),
            ),
            if (_result != null) ...[
              const SizedBox(height: 12),
              Text(_result!),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: printer == null || _printing ? null : _testPrint,
              child: Text(_printing ? 'Printing...' : 'Test print'),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy ? null : _refresh,
              child: Text(_busy ? 'Looking...' : 'Find printers'),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: ZebraBluetoothPrinter.showAccessoryPicker,
              child: const Text('Open Bluetooth settings'),
            ),
            const SizedBox(height: 8),
            Text(
              'Minimize keeps this running in the tray. Closing asks for the password. It also starts when you sign in to Windows.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyPrinters extends StatelessWidget {
  const _EmptyPrinters();

  @override
  Widget build(BuildContext context) {
    return const Align(
      alignment: Alignment.topLeft,
      child: Text(
        'Plug the ZQ320 into USB, or pair it in Windows Bluetooth settings, then press Find printers.',
      ),
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
