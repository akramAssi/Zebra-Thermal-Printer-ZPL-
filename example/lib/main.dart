import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

import 'long_invoice.dart';

void main() {
  runApp(const MaterialApp(home: ZebraSdkDemo()));
}

class ZebraSdkDemo extends StatefulWidget {
  const ZebraSdkDemo({Key? key}) : super(key: key);

  @override
  State<ZebraSdkDemo> createState() => _ZebraSdkDemoState();
}

class _ZebraSdkDemoState extends State<ZebraSdkDemo> {
  final _address = TextEditingController();
  final _port = TextEditingController(text: '9100');
  final _subnet = TextEditingController(text: '192.168.1.0');
  final _path = TextEditingController();
  final _linesCount = TextEditingController(text: '40');
  final _setting = TextEditingController(text: 'device.languages');
  final _value = TextEditingController(text: 'zpl');
  final _log = ScrollController();
  final _lines = <String>['Ready. Pick a use case.'];

  ZebraTransport _transport = ZebraTransport.bluetooth;
  StreamSubscription<dynamic>? _events;

  @override
  void initState() {
    super.initState();
    _events = ZebraBluetoothPrinter.eventChannel
        .receiveBroadcastStream()
        .listen((event) => _write('event: $event'));
  }

  @override
  void dispose() {
    _events?.cancel();
    _address.dispose();
    _port.dispose();
    _subnet.dispose();
    _path.dispose();
    _linesCount.dispose();
    _setting.dispose();
    _value.dispose();
    _log.dispose();
    super.dispose();
  }

  String get _target => _address.text.trim();
  int get _tcpPort => int.tryParse(_port.text.trim()) ?? 9100;

  Future<void> _run(String title, Future<Object?> Function() body) async {
    _write('— $title');
    try {
      final value = await body();
      _write(value == null ? 'ok' : '$value');
    } catch (error) {
      _write('error: $error');
    }
  }

  void _write(String line) {
    setState(() => _lines.add(line));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_log.hasClients) return;
      _log.jumpTo(_log.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Zebra SDK')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _address,
            decoration: const InputDecoration(
              labelText: 'Address',
              helperText:
                  'Android MAC, iOS serial, network IP, or USB device name',
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<ZebraTransport>(
            key: ValueKey(_transport),
            initialValue: _transport,
            decoration: const InputDecoration(labelText: 'Transport'),
            items: const [
              DropdownMenuItem(
                value: ZebraTransport.bluetooth,
                child: Text('Bluetooth'),
              ),
              DropdownMenuItem(
                value: ZebraTransport.tcp,
                child: Text('Network TCP'),
              ),
              DropdownMenuItem(
                value: ZebraTransport.usb,
                child: Text('USB (Android)'),
              ),
            ],
            onChanged: (value) {
              if (value != null) setState(() => _transport = value);
            },
          ),
          TextField(
            controller: _port,
            decoration: const InputDecoration(labelText: 'TCP port'),
            keyboardType: TextInputType.number,
          ),
          TextField(
            controller: _subnet,
            decoration: const InputDecoration(
              labelText: 'Network subnet',
              helperText:
                  '192.168.1.0 scans the subnet. A full IP probes that host.',
            ),
          ),
          TextField(
            controller: _path,
            decoration: const InputDecoration(
              labelText: 'Local file path',
              helperText: 'PDF, PNG, JPEG, or a file to store on the printer',
            ),
          ),
          TextField(
            controller: _setting,
            decoration: const InputDecoration(labelText: 'SGD setting'),
          ),
          TextField(
            controller: _value,
            decoration: const InputDecoration(labelText: 'SGD value'),
          ),
          const SizedBox(height: 12),
          const _Heading('Find a printer'),
          _button(
            'Bluetooth printers',
            () => _run('discoverBluetooth', () async {
              final printers = await ZebraSdk.discoverBluetooth();
              if (printers.isNotEmpty && _target.isEmpty) {
                _address.text = printers.first.address;
              }
              return printers
                  .map((printer) => '${printer.name}  ${printer.address}')
                  .join('\n');
            }),
          ),
          _button(
            'iOS accessory picker',
            () => _run('showAccessoryPicker', () async {
              return ZebraBluetoothPrinter.showAccessoryPicker();
            }),
          ),
          _button(
            'Network printers',
            () => _run('discoverNetwork', () async {
              final printers = await ZebraSdk.discoverNetwork(
                subnet: _subnet.text.trim(),
              );
              if (printers.isNotEmpty) {
                _address.text = printers.first.address;
                setState(() => _transport = ZebraTransport.tcp);
              }
              return printers
                  .map(
                    (printer) =>
                        '${printer.name}  ${printer.address}:${printer.port}',
                  )
                  .join('\n');
            }),
          ),
          _button(
            'USB printers',
            () => _run('discoverUsb', () async {
              final printers = await ZebraSdk.discoverUsb();
              if (printers.isNotEmpty) {
                _address.text = printers.first.address;
                setState(() => _transport = ZebraTransport.usb);
              }
              return printers
                  .map((printer) => '${printer.name}  ${printer.address}')
                  .join('\n');
            }),
          ),
          const _Heading('Session'),
          _button(
            'Connect',
            () => _run('connect', () {
              return ZebraSdk.connect(
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Is connected',
            () => _run('isConnected', ZebraSdk.isConnected),
          ),
          _button('Disconnect', () => _run('disconnect', ZebraSdk.disconnect)),
          const _Heading('Status and settings'),
          _button(
            'Status',
            () => _run('status', () async {
              final status = await _withTarget(ZebraSdk.status);
              return status.toMap();
            }),
          ),
          _button(
            'Printer info',
            () => _run('printerInfo', () => _withTarget(ZebraSdk.printerInfo)),
          ),
          _button(
            'Odometer',
            () => _run('odometer', () => _withTarget(ZebraSdk.odometer)),
          ),
          _button(
            'Storage',
            () => _run('storageInfo', () async {
              final drives = await _withTarget(ZebraSdk.storageInfo);
              return drives
                  .map(
                    (drive) =>
                        '${drive.driveLetter}: ${drive.driveType} ${drive.bytesFree} free',
                  )
                  .join('\n');
            }),
          ),
          _button(
            'SGD get',
            () => _run('get ${_setting.text}', () {
              return ZebraSdk.getSetting(
                _setting.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'SGD set',
            () => _run('set ${_setting.text}', () {
              return ZebraSdk.setSetting(
                _setting.text.trim(),
                _value.text,
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Set clock to now',
            () => _run('setClock', () {
              final now = DateTime.now();
              String two(int value) => value.toString().padLeft(2, '0');
              return ZebraSdk.setClock(
                date: '${two(now.month)}-${two(now.day)}-${now.year}',
                time: '${two(now.hour)}:${two(now.minute)}:${two(now.second)}',
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          const _Heading('Print'),
          _button(
            'Print ZPL',
            () => _run('printZpl', () {
              return ZebraSdk.printZpl(
                _zpl,
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Print CPCL',
            () => _run('printCpcl', () {
              return ZebraSdk.printCpcl(
                _cpcl,
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Print raw bytes',
            () => _run('printRaw', () {
              return ZebraSdk.printRaw(
                Uint8List.fromList(
                  '^XA^FO20,20^A0N,30,30^FDRaw^FS^XZ'.codeUnits,
                ),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          TextField(
            controller: _linesCount,
            decoration: const InputDecoration(
              labelText: 'Invoice lines',
              helperText:
                  'A long receipt, about 40 lines. Not the printer maximum.',
            ),
            keyboardType: TextInputType.number,
          ),
          _button(
            'Print long invoice',
            () => _run('print long invoice', () async {
              final count = int.tryParse(_linesCount.text.trim()) ?? 40;
              final invoice = await LongInvoice.build(lineCount: count);
              await ZebraSdk.printPdf(
                invoice.filePath,
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
              final inches = invoice.heightInches.toStringAsFixed(1);
              return '${invoice.lineCount} lines, one PDF, $inches inches tall';
            }),
          ),
          _button(
            'Print PDF file',
            () => _run('printPdf', () {
              return ZebraSdk.printPdf(
                _path.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Print image file',
            () => _run('printImage', () {
              return ZebraSdk.printImage(
                _path.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Store image as E:LOGO.GRF',
            () => _run('storeImage', () {
              return ZebraSdk.storeImage(
                'E:LOGO.GRF',
                _path.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          const _Heading('Tools'),
          _button(
            'Feed one label',
            () => _run('feed', () => _withTarget(ZebraSdk.feed)),
          ),
          _button(
            'Calibrate media',
            () => _run('calibrate', () => _withTarget(ZebraSdk.calibrate)),
          ),
          _button(
            'Configuration label',
            () => _run(
              'printConfigurationLabel',
              () => _withTarget(ZebraSdk.printConfigurationLabel),
            ),
          ),
          _button(
            'Network configuration label',
            () => _run(
              'printNetworkConfigurationLabel',
              () => _withTarget(ZebraSdk.printNetworkConfigurationLabel),
            ),
          ),
          _button(
            'Directory label',
            () => _run(
              'printDirectoryLabel',
              () => _withTarget(ZebraSdk.printDirectoryLabel),
            ),
          ),
          _button(
            'Restore defaults',
            () => _run(
              'restoreDefaults',
              () => _withTarget(ZebraSdk.restoreDefaults),
            ),
          ),
          _button(
            'Reset printer',
            () => _run('reset', () => _withTarget(ZebraSdk.reset)),
          ),
          const _Heading('Files and stored formats'),
          _button(
            'List E: files',
            () => _run('listFiles', () {
              return ZebraSdk.listFiles(
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Send local file to the printer',
            () => _run('sendFile', () {
              return ZebraSdk.sendFile(
                _path.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Store local file as E:DEMO.ZPL',
            () => _run('storeFile', () {
              return ZebraSdk.storeFile(
                'E:DEMO.ZPL',
                _path.text.trim(),
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'Store a format, then print it',
            () => _run('printStoredFormat', () async {
              await ZebraSdk.printZpl(
                _storedFormat,
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
              await ZebraSdk.printStoredFormat(
                'E:DEMO.ZPL',
                {1: 'Shini', 2: '12.50'},
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
              return ZebraFormat.fields(
                _storedFormat,
              ).map((field) => 'FN${field.number} ${field.name}').join(', ');
            }),
          ),
          _button(
            'Retrieve E:DEMO.ZPL',
            () => _run('retrieveFile', () async {
              final bytes = await ZebraSdk.retrieveFile(
                'E:DEMO.ZPL',
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
              return '${bytes.length} bytes';
            }),
          ),
          _button(
            'Delete E:DEMO.ZPL',
            () => _run('deleteFile', () {
              return ZebraSdk.deleteFile(
                'E:DEMO.ZPL',
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          _button(
            'SGD do file.dir',
            () => _run('do file.dir', () {
              return ZebraSdk.doCommand(
                'file.dir',
                value: 'E:',
                address: _target,
                transport: _transport,
                port: _tcpPort,
              );
            }),
          ),
          const SizedBox(height: 16),
          const _Heading('Log'),
          SizedBox(
            height: 220,
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.black12),
              ),
              child: ListView.builder(
                controller: _log,
                itemCount: _lines.length,
                itemBuilder: (context, index) => Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  child: Text(_lines[index]),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _button(String label, VoidCallback onPressed) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: OutlinedButton(onPressed: onPressed, child: Text(label)),
    );
  }

  Future<T> _withTarget<T>(
    Future<T> Function({String address, ZebraTransport transport, int port})
    call,
  ) {
    return call(address: _target, transport: _transport, port: _tcpPort);
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: Text(text, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}

const _zpl = '^XA^FO20,20^A0N,40,40^FDZebra SDK^FS^XZ';

const _cpcl = '! 0 200 200 210 1\r\nTEXT 4 0 30 40 CPCL\r\nPRINT\r\n';

const _storedFormat =
    '^XA'
    '^DFE:DEMO.ZPL^FS'
    '^FO20,20^A0N,30,30^FN1"Name"^FS'
    '^FO20,60^A0N,30,30^FN2"Price"^FS'
    '^XZ';
