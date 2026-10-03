import 'dart:io';

import 'package:flutter/services.dart';
import 'package:zebra_bluetooth_printer/method_channels.dart';
import 'package:zebra_bluetooth_printer/src/bluetooth_permission.dart';
import 'package:zebra_bluetooth_printer/src/zebra_models.dart';

/// Link-OS operations for Android and iOS.
///
/// Android calls the Zebra SDK (`SGD`, `ZebraPrinter`, `ToolsUtil`,
/// `FileUtil`, `GraphicsUtil`, `FormatUtil`, `NetworkDiscoverer`,
/// `UsbDiscoverer`). iOS sends the same ZPL, CPCL, SGD, and `~HS` commands
/// over the MFi raw port or a TCP socket on port 9100.
///
/// [connect] keeps the session open until [disconnect]. Pass [address] on a
/// later call only when you want to open a different printer. The older
/// `ZebraBluetoothPrinter.print` and `ZebraBluetoothPrinter.printPdf` methods
/// still close the connection when they finish.
class ZebraSdk {
  ZebraSdk._();

  static const MethodChannel _channel =
      MethodChannel('zebra_bluetooth_printer');

  /// Paired and nearby Bluetooth printers. On iOS this is the accessories
  /// already paired in Settings. Open the accessory picker when the list
  /// is empty.
  static Future<List<ZebraDiscoveredPrinter>> discoverBluetooth() async {
    if (Platform.isAndroid || Platform.isIOS) {
      final allowed = await requestBluetoothPermission();
      if (!allowed) return const [];
    }
    final raw =
        await _channel.invokeMethod<List<dynamic>>(Channels.listPrinters);
    if (raw == null) return const [];
    return [
      for (final item in raw)
        if (item is Map)
          ZebraDiscoveredPrinter(
            name: (item['name'] ?? '').toString(),
            address: (item['address'] ?? item['serialNumber'] ?? '').toString(),
            transport: ZebraTransport.bluetooth,
          ),
    ].where((printer) => printer.address.isNotEmpty).toList();
  }

  /// Printers answering Zebra discovery on the local network.
  ///
  /// Android uses `NetworkDiscoverer`. Pass [subnet] such as `192.168.1.255`
  /// for a directed broadcast. iOS has no Link-OS discovery packet, so pass
  /// a subnet such as `192.168.1.0` and the plugin probes port 9100.
  static Future<List<ZebraDiscoveredPrinter>> discoverNetwork({
    String subnet = '',
    int timeoutMs = 8000,
  }) async {
    final raw = await _invoke('discoverNetwork', {
      'subnet': subnet,
      'timeoutMs': timeoutMs,
    });
    return _printers(raw);
  }

  /// USB Zebra printers. Android only.
  static Future<List<ZebraDiscoveredPrinter>> discoverUsb() async {
    final raw = await _invoke('discoverUsb');
    return _printers(raw);
  }

  /// Opens a session. Later calls reuse it until [disconnect].
  static Future<void> connect({
    required String address,
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('connect', {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<void> disconnect() => _invoke('disconnect');

  static Future<bool> isConnected() async {
    final value = await _invoke('isConnected');
    return value == true;
  }

  /// `PrinterStatus` from the SDK, or the `~HS` reply on iOS.
  static Future<ZebraPrinterStatus> status({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('status', {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    return ZebraPrinterStatus.fromMap(_map(raw));
  }

  /// `SGD.GET`. Example: `device.languages`, `ezpl.media_type`, `print.tone`.
  static Future<String> getSetting(
    String setting, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final value = await _invoke('get', {
      'setting': setting,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    return value?.toString() ?? '';
  }

  /// `SGD.SET`.
  static Future<void> setSetting(
    String setting,
    String value, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('set', {
      'setting': setting,
      'value': value,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// `SGD.DO`, for printer actions such as `file.dir` or `file.delete`.
  static Future<String> doCommand(
    String command, {
    String value = '',
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final result = await _invoke('do', {
      'command': command,
      'value': value,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    return result?.toString() ?? '';
  }

  /// Host id, language, firmware, media, darkness, speed, and battery.
  static Future<Map<String, String>> printerInfo({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('hostInfo', {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    final map = _map(raw);
    return map.map((key, value) => MapEntry('$key', '$value'));
  }

  static Future<void> printZpl(
    String zpl, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printZpl', {
      'data': zpl,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<void> printCpcl(
    String cpcl, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printCpcl', {
      'data': cpcl,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Bytes already encoded for the printer. No language change is applied.
  static Future<void> printRaw(
    Uint8List bytes, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printRaw', {
      'bytes': bytes,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Sends a PDF through Zebra PDF Direct (`apl`).
  static Future<void> printPdf(
    String filePath, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return printPdfs(
      [filePath],
      address: address,
      transport: transport,
      port: port,
    );
  }

  static Future<void> printPdfs(
    List<String> filePaths, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printPdfs', {
      'paths': filePaths,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Prints a PNG or JPEG. Android uses `GraphicsUtil.printImage`.
  /// Width and height `0` keep the source size. Dots, not millimeters.
  static Future<void> printImage(
    String filePath, {
    int x = 0,
    int y = 0,
    int width = 0,
    int height = 0,
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printImage', {
      'path': filePath,
      'x': x,
      'y': y,
      'width': width,
      'height': height,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Stores an image on the printer, for example `E:LOGO.GRF`.
  static Future<void> storeImage(
    String printerPath,
    String filePath, {
    int width = 0,
    int height = 0,
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('storeImage', {
      'printerPath': printerPath,
      'path': filePath,
      'width': width,
      'height': height,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// `ToolsUtil.calibrate` (`~JC`).
  static Future<void> calibrate({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('calibrate', address: address, transport: transport, port: port);

  /// `ToolsUtil.printConfigurationLabel` (`~WC`).
  static Future<void> printConfigurationLabel({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('printConfigurationLabel',
          address: address, transport: transport, port: port);

  /// `~WL`.
  static Future<void> printNetworkConfigurationLabel({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('printNetworkConfigurationLabel',
          address: address, transport: transport, port: port);

  /// `^WD`.
  static Future<void> printDirectoryLabel({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('printDirectoryLabel',
          address: address, transport: transport, port: port);

  /// Feeds one blank label (`^PH`).
  static Future<void> feed({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('feed', address: address, transport: transport, port: port);

  /// `ToolsUtil.restoreDefaults` (`^JUF`). Clears printer settings.
  static Future<void> restoreDefaults({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('restoreDefaults',
          address: address, transport: transport, port: port);

  /// `ToolsUtil.reset` (`~JR`). The printer reboots.
  static Future<void> reset({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) =>
      _tool('reset', address: address, transport: transport, port: port);

  static Future<void> _tool(
    String op, {
    required String address,
    required ZebraTransport transport,
    required int port,
  }) {
    return _invoke(op, {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Files on a printer drive. [drive] is `E:` for flash.
  static Future<List<String>> listFiles({
    String drive = 'E:',
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('listFiles', {
      'drive': drive,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    if (raw is List) {
      return raw.map((item) => item.toString()).toList();
    }
    return const [];
  }

  /// Saves a local file onto the printer. [printerPath] looks like `E:LOGO.GRF`.
  static Future<void> storeFile(
    String printerPath,
    String localPath, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('storeFile', {
      'printerPath': printerPath,
      'path': localPath,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  /// Writes a local file straight to the print channel. Use this for a ZPL
  /// file or a PDF. It does not save the file on the printer drive.
  static Future<void> sendFile(
    String localPath, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('sendFile', {
      'path': localPath,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<void> deleteFile(
    String printerPath, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('deleteFile', {
      'printerPath': printerPath,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<Uint8List> retrieveFile(
    String printerPath, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('retrieveFile', {
      'printerPath': printerPath,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    if (raw is Uint8List) return raw;
    if (raw is List) return Uint8List.fromList(raw.cast<int>());
    return Uint8List(0);
  }

  /// Prints a format already stored on the printer.
  /// Keys are `^FN` numbers. See [ZebraFormat.fields].
  static Future<void> printStoredFormat(
    String printerPath,
    Map<int, String> fields, {
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('printStoredFormat', {
      'printerPath': printerPath,
      'fields': fields.map((key, value) => MapEntry('$key', value)),
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<List<ZebraStorageInfo>> storageInfo({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('storageInfo', {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ZebraStorageInfo.fromMap(item),
    ];
  }

  /// Label odometers: total, user, and media marker counts.
  static Future<Map<String, String>> odometer({
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) async {
    final raw = await _invoke('odometer', {
      'address': address,
      'transport': transport.name,
      'port': port,
    });
    final map = _map(raw);
    return map.map((key, value) => MapEntry('$key', '$value'));
  }

  /// Sets the printer clock. [date] is `MM-DD-YYYY`, [time] is `HH:MM:SS`.
  static Future<void> setClock({
    required String date,
    required String time,
    String address = '',
    ZebraTransport transport = ZebraTransport.bluetooth,
    int port = 9100,
  }) {
    return _invoke('setClock', {
      'date': date,
      'time': time,
      'address': address,
      'transport': transport.name,
      'port': port,
    });
  }

  static Future<dynamic> _invoke(
    String op, [
    Map<String, Object?> args = const {},
  ]) async {
    final transport = zebraTransportFromName(args['transport']?.toString());
    if (transport == ZebraTransport.bluetooth &&
        args.containsKey('transport') &&
        (Platform.isAndroid || Platform.isIOS)) {
      final allowed = await requestBluetoothPermission();
      if (!allowed) {
        throw PlatformException(
          code: '004',
          message: 'Bluetooth permission is required',
        );
      }
    }
    return _channel.invokeMethod(Channels.sdk, {'op': op, ...args});
  }

  static List<ZebraDiscoveredPrinter> _printers(dynamic raw) {
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) ZebraDiscoveredPrinter.fromMap(item),
    ];
  }

  static Map<dynamic, dynamic> _map(dynamic raw) {
    if (raw is Map) return raw;
    return const {};
  }
}
