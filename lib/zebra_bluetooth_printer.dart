import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:zebra_bluetooth_printer/method_channels.dart';
import 'package:zebra_bluetooth_printer/src/bluetooth_permission.dart';

export 'src/zebra_models.dart';
export 'src/zebra_sdk.dart';

class ZebraAccessory {
  final String name;

  /// MAC address on Android, accessory serial number on iOS.
  final String address;

  const ZebraAccessory({required this.name, required this.address});

  String get serialNumber => address;
}

class ZebraBluetoothPrinter {
  static const MethodChannel _channel =
      MethodChannel('zebra_bluetooth_printer');

  static const EventChannel eventChannel =
      EventChannel('zebra_bluetooth_printer_stream');
  static Stream? _printStream;

  static Future<String?> get platformVersion async {
    final String? version =
        await _channel.invokeMethod(Channels.getPlatformVersion);
    return version;
  }

  static Future<dynamic> print(String zpl, String macAddress) async {
    debugPrint('[ZebraBT] print zpl address=$macAddress chars=${zpl.length}');
    final printed = await _channel.invokeMethod(Channels.printZpl, [macAddress, zpl]);
    debugPrint('[ZebraBT] print zpl result=$printed');
    return printed;
  }

  static Future<dynamic> printPdf(String macAddress, String filePath) async {
    debugPrint('[ZebraBT] printPdf address=$macAddress file=$filePath');
    final printed =
        await _channel.invokeMethod(Channels.printPDf, [macAddress, filePath]);
    debugPrint('[ZebraBT] printPdf result=$printed');
    return printed;
  }

  /// Sends every page on one connection so a long invoice does not pause
  /// and feed between labels.
  static Future<dynamic> printPdfs(String macAddress, List<String> filePaths) async {
    debugPrint(
      '[ZebraBT] printPdfs address=$macAddress files=${filePaths.length}',
    );
    final printed = await _channel
        .invokeMethod(Channels.printPdfs, [macAddress, ...filePaths]);
    debugPrint('[ZebraBT] printPdfs result=$printed');
    return printed;
  }

  /// Firmware id such as ZQ520 or ZQ320. Empty when the printer cannot be reached.
  static Future<String> hostIdentification(String address) async {
    if (address.isEmpty) return '';
    if (Platform.isAndroid && !await requestBluetoothPermission()) return '';
    final value = await _channel.invokeMethod<String>(
      Channels.hostIdentification,
      address,
    );
    return value ?? '';
  }

  //
  // static Future<String?> checkConnection(String macAddress) async {
  //   final String? version = await _channel.invokeMethod('checkConnection', macAddress);
  //   return version;
  // }

  static Stream? printStream() {
    _printStream ??= eventChannel.receiveBroadcastStream();
    return _printStream;
  }

  static Future<bool?> connect(String macAddress) async {
    if (!await requestBluetoothPermission()) return false;
    return _channel.invokeMethod(Channels.connect, macAddress);
  }

  /// Paired and nearby Zebra printers on Android, or already paired printers on iOS.
  static Future<List<ZebraAccessory>> connectedPrinters() async {
    if (Platform.isAndroid && !await requestBluetoothPermission()) {
      return const [];
    }
    debugPrint('[ZebraBT] connectedPrinters request');
    final raw = await _channel.invokeMethod<Object?>(Channels.listPrinters);
    debugPrint(
        '[ZebraBT] connectedPrinters rawType=${raw.runtimeType} raw=$raw');
    if (raw is! List) return const [];
    final printers = raw
        .map((item) {
          if (item is! Map) return null;
          final map = Map<String, dynamic>.from(item);
          final address =
              (map['address'] ?? map['serialNumber'] ?? '').toString();
          return ZebraAccessory(
            name: (map['name'] ?? '').toString(),
            address: address,
          );
        })
        .whereType<ZebraAccessory>()
        .where((printer) => printer.address.isNotEmpty)
        .toList();
    debugPrint(
      '[ZebraBT] connectedPrinters count=${printers.length} '
      '${printers.map((printer) => '${printer.name} ${printer.address}').join(' | ')}',
    );
    return printers;
  }

  /// Opens the iOS Bluetooth accessory picker so the user can pair a Zebra printer.
  static Future<bool?> showAccessoryPicker() async {
    debugPrint('[ZebraBT] showAccessoryPicker request');
    final opened = await _channel.invokeMethod<bool>(Channels.showPicker);
    debugPrint('[ZebraBT] showAccessoryPicker result=$opened');
    return opened;
  }

  static Future<bool> ensureBluetoothPermission() =>
      requestBluetoothPermission();

  static Future<bool?> disconnect() async {
    return _channel.invokeMethod(Channels.discount);
  }
}
