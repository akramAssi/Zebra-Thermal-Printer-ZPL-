import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

import 'agent_log.dart';
import 'close_password.dart';
import 'local_print_server.dart';
import 'print_queue.dart';
import 'printer_setup.dart';
import 'receipt_pdf.dart';

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
  PrinterLink _usbLink = PrinterLink.unplugged;
  LocalPrintServer? _printServer;
  List<PrintJob> _jobs = const [];
  bool _cancellingJobs = false;

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
    unawaited(_printServer?.close());
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
    await _openPortalPrint();
    await _watch();
    await _loadJobs();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      _watch();
      _loadJobs();
    });
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
      if (_setupPaused) return;
      final needsDriver = !machine.driverReady && !machine.driverPackage;
      if (needsDriver) {
        await _prepare(installingDriver: true);
        return;
      }
      if (usbReady || !machine.usbConnected || machine.queueReady) {
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

  Future<void> _prepare({bool installingDriver = false}) async {
    _settingUp = true;
    if (mounted) {
      setState(() {
        _status = installingDriver
            ? 'Installing the printer driver. If Windows asks, press Yes.'
            : 'Setting up the printer. If Windows asks, press Yes.';
      });
    }
    agentLog(
      installingDriver
          ? 'Printer driver is missing. Installing the bundled driver first.'
          : 'Setting up the printer queue.',
    );
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
        agentLog('The bundled printer driver was not installed.');
        setState(() {
          _status = 'The printer driver could not be installed.';
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
    } catch (error) {
      agentLog('Printer search failed: $error');
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

  Future<void> _loadJobs() async {
    if (_cancellingJobs) return;
    final jobs = await readPrintJobs();
    if (!mounted || jobs == null || _cancellingJobs) return;
    setState(() => _jobs = jobs);
  }

  Future<void> _cancelJobs(List<PrintJob> jobs) async {
    if (_cancellingJobs || jobs.isEmpty) return;
    setState(() {
      _cancellingJobs = true;
      _result = jobs.length == 1
          ? 'Canceling the print job. If Windows asks, press Yes.'
          : 'Canceling the print jobs. If Windows asks, press Yes.';
    });
    agentLog(
      'Canceling print ${jobs.length == 1 ? 'job' : 'jobs'} ${jobs.map((job) => job.id).join(', ')}.',
    );
    final result = await cancelPrintJobs(jobs.map((job) => job.id).toList());
    final next = await readPrintJobs();
    if (!mounted) return;
    setState(() {
      _cancellingJobs = false;
      if (next != null) _jobs = next;
      _result = switch (result) {
        CancelJobsResult.cleared => jobs.length == 1
            ? 'Print job canceled.'
            : 'Print jobs canceled.',
        CancelJobsResult.needPermission =>
          'Windows needs permission to cancel the stuck print job.',
        CancelJobsResult.failed => 'The print job could not be canceled.',
      };
    });
    agentLog(_result ?? 'Print job cancel finished.');
  }

  Future<void> _openPortalPrint() async {
    try {
      final server = await LocalPrintServer.start(
        printerReady: _agentPrinterReady,
        printerName: _agentPrinterName,
        printPng: _printPortalPng,
        log: agentLog,
      );
      if (!mounted) {
        await server.close();
        return;
      }
      _printServer = server;
      agentLog('Portal print is listening on 127.0.0.1:${LocalPrintServer.port}.');
    } catch (error) {
      agentLog('Portal print could not start: $error');
    }
  }

  bool _agentPrinterReady() {
    final printer = _current;
    if (printer == null) return false;
    if (printer.transport == ZebraTransport.bluetooth) return true;
    return _usbLink.canPrint;
  }

  String _agentPrinterName() {
    final printer = _current;
    if (printer == null) return '';
    return printer.name.isEmpty ? printer.address : printer.name;
  }

  Future<void> _printPortalPng(Uint8List png) async {
    final printer = _current;
    if (printer == null || !_agentPrinterReady()) {
      throw StateError('Printer is not ready.');
    }
    if (mounted) {
      setState(() {
        _printing = true;
        _result = null;
      });
    } else {
      _printing = true;
    }
    try {
      final pdf = await pngToReceiptPdf(png);
      await _sendPdf(pdf, printer);
      agentLog('Portal receipt sent to ${printer.address}.');
      if (mounted) setState(() => _result = 'Receipt sent.');
    } catch (error) {
      agentLog('Portal receipt failed: $error');
      if (mounted) setState(() => _result = 'Receipt was not printed.');
      rethrow;
    } finally {
      if (mounted) {
        setState(() => _printing = false);
      } else {
        _printing = false;
      }
    }
  }

  Future<void> _testPrint() async {
    final printer = _current;
    if (printer == null || _printing) return;
    setState(() {
      _printing = true;
      _result = null;
    });
    final label = await testLabelPdf(
      title: 'Zebra test',
      detail: '${printer.transport == ZebraTransport.usb ? 'USB' : 'Bluetooth'}  ${_plainText(printer.name.isEmpty ? 'Zebra' : printer.name)}',
      address: _plainText(printer.address),
    );
    try {
      await _sendPdf(label, printer);
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

  Future<void> _sendPdf(Uint8List pdf, ZebraDiscoveredPrinter printer) async {
    final file = File(
      '${Directory.systemTemp.path}\\receipt-${DateTime.now().millisecondsSinceEpoch}.pdf',
    );
    await file.writeAsBytes(pdf, flush: true);
    try {
      await ZebraSdk.printPdf(
        file.path,
        address: printer.address,
        transport: printer.transport,
        port: printer.port,
      );
    } finally {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  String _plainText(String value) {
    return value.replaceAll(RegExp(r'[^A-Za-z0-9 :.-]'), ' ');
  }

  bool get _canPrint {
    final printer = _current;
    if (printer == null || _printing) return false;
    if (printer.transport == ZebraTransport.bluetooth) return true;
    return _usbLink.canPrint;
  }

  Widget _jobTile(PrintJob job) {
    final status = job.status.isEmpty ? 'Waiting' : job.status;
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(12),
      child: ListTile(
        leading: const Icon(Icons.print_outlined),
        title: Text(job.title, maxLines: 2, overflow: TextOverflow.ellipsis),
        subtitle: Text(status),
        trailing: TextButton(
          onPressed: _cancellingJobs ? null : () => _cancelJobs([job]),
          child: const Text('Cancel'),
        ),
      ),
    );
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
                  if (_jobs.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('Print queue', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 8),
                    for (final job in _jobs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: _jobTile(job),
                      ),
                    if (_jobs.length > 1)
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: _cancellingJobs ? null : () => _cancelJobs(_jobs),
                          child: const Text('Cancel all'),
                        ),
                      ),
                  ],
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
                _status.startsWith('The printer could not') ||
                _status.startsWith('The printer driver could not')) ...[
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
              _printServer == null
                  ? 'Leave this window open. It keeps working when minimized.'
                  : 'Leave this window open. The portal on this computer prints a 72 mm roll here.',
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
      agentLog('Close was rejected. The typed password did not match.');
      setState(() => _wrong = true);
      return;
    }
    agentLog('Close password matched.');
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
