import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

import 'close_password.dart';
import 'portal_print_link.dart';
import 'portal_print_server.dart';
import 'windows_driver.dart';

/// iOS / Android app: explore and connect a Zebra, take labels from the portal
/// (local listener + deep links) into a print queue.

class MobilePrinterHome extends StatefulWidget {
  const MobilePrinterHome({super.key});

  @override
  State<MobilePrinterHome> createState() => _MobilePrinterHomeState();
}

class _MobilePrinterHomeState extends State<MobilePrinterHome>
    with WindowListener, TrayListener {
  List<ZebraDiscoveredPrinter> _printers = const [];
  String? _selected;
  String _status = 'Looking for a printer...';
  String? _result;
  bool _busy = false;
  bool _connecting = false;
  bool _printing = false;
  bool _askingPassword = false;
  String _password = kDefaultClosePassword;
  WindowsDriverStatus? _driver;
  bool _installingDriver = false;
  PortalPrintServer? _portal;
  String _portalNote = 'Starting the portal listener...';
  final List<_PortalJob> _jobs = [];
  bool _draining = false;
  bool _sendingTestFile = false;
  final _appLinks = AppLinks();
  StreamSubscription<Uri>? _portalLinkSub;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
    }
    _start();
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _portalLinkSub?.cancel();
    _portal?.close();
    super.dispose();
  }

  Future<void> _start() async {
    if (Platform.isWindows) await windowManager.setPreventClose(true);
    final password = await loadClosePassword();
    if (mounted) setState(() => _password = password);
    if (Platform.isWindows) {
      await _setupTray();
      await _enableLoginStart();
      await _checkDriver();
    }
    await _openPortalListener();
    await _listenForDeepLinks();
    await _refresh();
  }

  Future<void> _listenForDeepLinks() async {
    try {
      final initial = await _appLinks.getInitialLink();
      if (initial != null) await _takePortalLink(initial);
    } catch (error) {
      debugPrint('Deep link was not read: $error');
    }
    _portalLinkSub = _appLinks.uriLinkStream.listen(
      (uri) {
        unawaited(_takePortalLink(uri));
      },
      onError: (Object error) {
        debugPrint('Deep link failed: $error');
      },
    );
  }

  Future<void> _takePortalLink(Uri uri) async {
    final link = portalPrintLinkFrom(uri);
    if (link == null) return;
    if (mounted) {
      setState(() => _portalNote = 'Opening the label from the portal...');
    }
    final client = HttpClient();
    try {
      final request = await client.getUrl(link.fileUri);
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      final bytes = await response.fold<List<int>>(
        <int>[],
        (previous, chunk) => previous..addAll(chunk),
      );
      if (response.statusCode != 200 || !looksLikePng(bytes)) {
        if (!mounted) return;
        setState(() => _portalNote = 'The portal file was not available.');
        return;
      }
      await _acceptPortalFile(bytes);
    } catch (error) {
      if (!mounted) return;
      setState(() => _portalNote = 'The portal file did not open. $error');
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _openPortalListener() async {
    final server = PortalPrintServer(onFile: _acceptPortalFile);
    try {
      await server.start();
      if (!mounted) {
        await server.close();
        return;
      }
      setState(() {
        _portal = server;
        _portalNote = 'Waiting for a label from the portal.';
      });
      _syncPortalPrinter();
    } catch (error) {
      await server.close();
      if (!mounted) return;
      setState(() => _portalNote = 'Portal listener did not start. $error');
    }
  }

  void _syncPortalPrinter() {
    final server = _portal;
    if (server == null) return;
    final printer = _current;
    final name = printer == null
        ? ''
        : (printer.name.isEmpty ? printer.address : printer.name);
    server.printerName = name;
    server.printerReady = printer != null || !Platform.isWindows;
  }

  Future<PortalPrintResult> _acceptPortalFile(List<int> bytes) async {
    final job = _PortalJob(Uint8List.fromList(bytes));
    if (mounted) {
      setState(() {
        _jobs.add(job);
        _portalNote = 'Label ${job.id} is in the queue.';
      });
    }
    await _drainQueue();
    return PortalPrintResult(
      printed: job.status == _PortalJobStatus.printed,
      message: job.message,
    );
  }

  Future<void> _drainQueue() async {
    if (_draining) return;
    _draining = true;
    try {
      while (mounted) {
        final waiting = _jobs.any(
          (job) => job.status == _PortalJobStatus.queued,
        );
        if (!waiting) return;
        final printer = await _printerForQueue();
        if (printer == null) {
          if (mounted) {
            setState(
              () => _portalNote = 'Labels are waiting. Connect a printer.',
            );
          }
          return;
        }
        final job = _jobs.firstWhere(
          (item) => item.status == _PortalJobStatus.queued,
        );
        await _printQueued(job, printer);
      }
    } finally {
      _draining = false;
    }
  }

  Future<ZebraDiscoveredPrinter?> _printerForQueue() async {
    if (_current != null) return _current;
    if (_printers.isEmpty && !_busy) await _refresh();
    if (_current != null) return _current;
    if (_printers.length == 1 && !_connecting && !_busy) {
      await _connectPrinter(_printers.first);
    }
    return _current;
  }

  Future<void> _printQueued(
    _PortalJob job,
    ZebraDiscoveredPrinter printer,
  ) async {
    if (mounted) {
      setState(() {
        job.status = _PortalJobStatus.printing;
        _portalNote = 'Printing label ${job.id}.';
      });
    }
    final file = File(
      '${Directory.systemTemp.path}${Platform.pathSeparator}portal-label-${job.id}.png',
    );
    await file.writeAsBytes(job.png, flush: true);
    try {
      await ZebraSdk.printImage(
        file.path,
        address: printer.address,
        transport: printer.transport,
        port: printer.port,
      );
      job.status = _PortalJobStatus.printed;
      job.message = 'Printed.';
      if (mounted) setState(() => _portalNote = 'Label ${job.id} printed.');
    } catch (error) {
      job.status = _PortalJobStatus.failed;
      job.message = '$error';
      if (mounted) {
        setState(() => _portalNote = 'Label ${job.id} did not print. $error');
      }
    }
  }

  Future<void> _sendTestFile() async {
    final server = _portal;
    if (server == null || _sendingTestFile) return;
    setState(() => _sendingTestFile = true);
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${server.port}/print'),
      );
      request.headers.contentType = ContentType('image', 'png');
      request.add(kPortalTestPng);
      final response = await request.close().timeout(
        const Duration(seconds: 8),
      );
      final text = await utf8.decoder.bind(response).join();
      if (!mounted) return;
      if (response.statusCode == 200) return;
      setState(() => _portalNote = 'Test file was refused ($text).');
    } catch (error) {
      if (!mounted) return;
      setState(() => _portalNote = 'Test file did not arrive. $error');
    } finally {
      client.close(force: true);
      if (mounted) setState(() => _sendingTestFile = false);
    }
  }

  Future<void> _checkDriver() async {
    final status = await checkWindowsDriver();
    if (!mounted) return;
    setState(() => _driver = status);
  }

  Future<void> _installDriver() async {
    final path = _driver?.installerPath ?? '';
    if (path.isEmpty || _installingDriver) return;
    setState(() {
      _installingDriver = true;
      _result = null;
    });
    final message = await installWindowsDriver(path);
    if (!mounted) return;
    setState(() {
      _installingDriver = false;
      _result = message;
    });
    await _checkDriver();
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
      final lookups = <Future<List<ZebraDiscoveredPrinter>>>[
        ZebraSdk.discoverBluetooth(),
      ];
      if (!Platform.isIOS) lookups.add(ZebraSdk.discoverUsb());
      final found = await Future.wait(lookups);
      final printers = [for (final list in found) ...list];
      if (!mounted) return;
      setState(() {
        _printers = printers;
        _selected = _keepSelection(printers);
        _status = _statusFor(printers);
      });
      _syncPortalPrinter();
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _printers = const [];
        _selected = null;
        _status = error.message ?? 'Could not look for printers.';
      });
      _syncPortalPrinter();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _printers = const [];
        _selected = null;
        _status = '$error';
      });
      _syncPortalPrinter();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _keepSelection(List<ZebraDiscoveredPrinter> printers) {
    for (final printer in printers) {
      if (_key(printer) == _selected) return _selected;
    }
    if (printers.isEmpty || !Platform.isWindows) return null;
    return _key(printers.first);
  }

  String _statusFor(List<ZebraDiscoveredPrinter> printers) {
    if (printers.isEmpty) {
      if (!Platform.isWindows) {
        return 'No printer connected. Explore devices to connect over Bluetooth.';
      }
      return 'No printer found. Plug in USB, or pair the Zebra over Bluetooth.';
    }
    final count =
        '${printers.length} printer${printers.length == 1 ? '' : 's'} found.';
    if (!Platform.isWindows && _selected == null) {
      return '$count Tap one to connect.';
    }
    return count;
  }

  String _printerTitle(ZebraDiscoveredPrinter printer) {
    return printer.name.isEmpty ? printer.address : printer.name;
  }

  Future<void> _exploreDevices() async {
    if (_busy || _connecting) return;
    if (Platform.isIOS) {
      setState(() {
        _status = 'Choose a Zebra printer from the Bluetooth devices.';
        _result = null;
      });
      try {
        await ZebraBluetoothPrinter.showAccessoryPicker();
      } on PlatformException catch (error) {
        if (!mounted) return;
        setState(
          () => _status = error.message ?? 'Could not open Bluetooth devices.',
        );
      } catch (error) {
        if (!mounted) return;
        setState(() => _status = '$error');
      }
    }
    await _refresh();
  }

  Future<void> _connectPrinter(ZebraDiscoveredPrinter printer) async {
    if (_connecting || _busy) return;
    final title = _printerTitle(printer);
    setState(() {
      _connecting = true;
      _selected = _key(printer);
      _result = null;
      _status = 'Connecting to $title...';
    });
    try {
      await ZebraSdk.connect(
        address: printer.address,
        transport: printer.transport,
        port: printer.port,
      );
      if (!mounted) return;
      setState(() => _status = 'Connected to $title.');
      _syncPortalPrinter();
      if (!_draining) unawaited(_drainQueue());
    } on PlatformException catch (error) {
      if (!mounted) return;
      setState(() {
        _selected = null;
        _status = error.message ?? 'Could not connect to $title.';
      });
      _syncPortalPrinter();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selected = null;
        _status = 'Could not connect to $title. $error';
      });
      _syncPortalPrinter();
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
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
      if (Platform.isWindows) {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
        return;
      }
      await SystemNavigator.pop();
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
    return PopScope(
      canPop: Platform.isWindows,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || Platform.isWindows) return;
        _exit();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(Platform.isIOS ? 'Printer Press' : 'Zebra Printer'),
        ),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_status, style: Theme.of(context).textTheme.titleMedium),
              if (!Platform.isWindows) ...[
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy || _connecting ? null : _exploreDevices,
                  icon: const Icon(Icons.bluetooth_searching),
                  label: Text(_busy ? 'Exploring...' : 'Explore devices'),
                ),
              ],
              if (Platform.isWindows) ...[
                const SizedBox(height: 12),
                _portalInbox(),
                const SizedBox(height: 12),
                _DriverNotice(
                  driver: _driver,
                  installing: _installingDriver,
                  onInstall: _installDriver,
                ),
              ],
              const SizedBox(height: 12),
              Expanded(child: _printerList()),
              if (!Platform.isWindows) ...[
                const SizedBox(height: 12),
                _portalInbox(),
              ],
              if (_result != null) ...[
                const SizedBox(height: 12),
                Text(_result!),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: printer == null || _printing ? null : _testPrint,
                child: Text(_printing ? 'Printing...' : 'Test print'),
              ),
              if (Platform.isWindows) ...[
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
              ],
              if (!Platform.isWindows) ...[
                const SizedBox(height: 8),
                TextButton(onPressed: _exit, child: const Text('Close app')),
              ],
              const SizedBox(height: 8),
              Text(_footer, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }

  Widget _portalInbox() {
    return _PortalInbox(
      note: _portalNote,
      jobs: _jobs,
      sending: _sendingTestFile,
      onTest: _portal == null ? null : _sendTestFile,
    );
  }

  Widget _printerList() {
    if (_printers.isEmpty) return _EmptyPrinters(hint: _emptyHint);
    return ListView.separated(
      itemCount: _printers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final item = _printers[index];
        final selected = _key(item) == _selected;
        final usb = item.transport == ZebraTransport.usb;
        final trailing = Platform.isWindows
            ? (usb ? 'USB' : 'Bluetooth')
            : (_connecting && selected
                  ? 'Connecting...'
                  : selected
                  ? 'Connected'
                  : 'Connect');
        return Material(
          color: selected
              ? Theme.of(context).colorScheme.secondaryContainer
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          child: ListTile(
            selected: selected,
            leading: Icon(usb ? Icons.usb : Icons.bluetooth),
            title: Text(item.name.isEmpty ? item.address : item.name),
            subtitle: Text(item.address),
            trailing: Text(trailing),
            onTap: Platform.isWindows
                ? () {
                    setState(() => _selected = _key(item));
                    _syncPortalPrinter();
                  }
                : () => _connectPrinter(item),
          ),
        );
      },
    );
  }

  String get _emptyHint {
    if (!Platform.isWindows) {
      return 'Turn the Zebra on. Explore devices, then tap the printer to connect.';
    }
    return 'Plug the ZQ320 into USB, or pair it in Windows Bluetooth settings, then press Find printers.';
  }

  String get _footer {
    if (Platform.isWindows) {
      return 'Minimize keeps this running in the tray. Closing asks for the password. It also starts when you sign in to Windows.';
    }
    return 'Closing asks for the password from the portal. A label from the portal joins the print queue.';
  }
}

enum _PortalJobStatus { queued, printing, printed, failed }

class _PortalJob {
  _PortalJob(this.png) : id = _next++;

  static int _next = 1;

  final int id;
  final Uint8List png;
  _PortalJobStatus status = _PortalJobStatus.queued;
  String message = '';

  String get label {
    switch (status) {
      case _PortalJobStatus.queued:
        return 'Queued';
      case _PortalJobStatus.printing:
        return 'Printing';
      case _PortalJobStatus.printed:
        return 'Printed';
      case _PortalJobStatus.failed:
        return 'Failed';
    }
  }
}

class _PortalInbox extends StatelessWidget {
  const _PortalInbox({
    required this.note,
    required this.jobs,
    required this.sending,
    required this.onTest,
  });

  final String note;
  final List<_PortalJob> jobs;
  final bool sending;
  final VoidCallback? onTest;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = jobs.length <= 5 ? jobs : jobs.sublist(jobs.length - 5);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Print queue', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            Text(jobs.isEmpty ? 'Waiting for a label from the portal.' : note),
            if (visible.isNotEmpty) ...[
              const SizedBox(height: 8),
              for (final job in visible) ...[
                Row(
                  children: [
                    Image.memory(
                      job.png,
                      width: 42,
                      height: 42,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const SizedBox(width: 42),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text('Label ${job.id}')),
                    Text(job.label, style: theme.textTheme.labelLarge),
                  ],
                ),
                const SizedBox(height: 8),
              ],
            ],
            OutlinedButton(
              onPressed: onTest == null || sending ? null : onTest,
              child: Text(sending ? 'Sending...' : 'Test portal file'),
            ),
          ],
        ),
      ),
    );
  }
}

class _DriverNotice extends StatelessWidget {
  const _DriverNotice({
    required this.driver,
    required this.installing,
    required this.onInstall,
  });

  final WindowsDriverStatus? driver;
  final bool installing;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    final status = driver;
    if (status == null) {
      return Text(
        'Checking the printer driver...',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    if (status.installed) {
      return Text(
        'Zebra driver is installed.',
        style: Theme.of(context).textTheme.bodySmall,
      );
    }
    final missingInstaller = status.installerPath.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          missingInstaller
              ? 'USB needs the Zebra printer driver. This app does not include the installer yet. Save Zebra Setup Utilities as driver\\ZebraDriver.exe and build again. Bluetooth works without it.'
              : 'USB needs the Zebra printer driver. Bluetooth works without it.',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (status.checkFailed) ...[
          const SizedBox(height: 8),
          Text(
            'The driver check did not finish. You can still install it.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        if (!missingInstaller) ...[
          const SizedBox(height: 8),
          FilledButton(
            onPressed: installing ? null : onInstall,
            child: Text(installing ? 'Installing...' : 'Install driver'),
          ),
        ],
      ],
    );
  }
}

class _EmptyPrinters extends StatelessWidget {
  const _EmptyPrinters({required this.hint});

  final String hint;

  @override
  Widget build(BuildContext context) {
    return Align(alignment: Alignment.topLeft, child: Text(hint));
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
      title: Text(
        Platform.isIOS ? 'Close Printer Press' : 'Close Zebra Printer',
      ),
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
