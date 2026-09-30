import 'dart:async';
import 'dart:developer';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:zebra_bluetooth_printer/method_channels.dart';

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

  static Future<int?> get platformVersion async {
    final int? version =
        await _channel.invokeMethod(Channels.getPlatformVersion);
    return version;
  }

  static Future<dynamic> print(String zpl, String macAddress) async {
    return _channel.invokeMethod(Channels.printZpl, [macAddress, zpl]);
  }

  static Future<dynamic> printPdf(String macAddress, String filePath) async {
    return _channel.invokeMethod(Channels.printPDf, [macAddress, filePath]);
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
    if (!await _ensureBluetoothPermission()) return false;
    return _channel.invokeMethod(Channels.connect, macAddress);
  }

  /// Zebra printers found by the Zebra SDK on Android, or already paired on iOS.
  static Future<List<ZebraAccessory>> connectedPrinters() async {
    if (Platform.isAndroid && !await _ensureBluetoothPermission()) {
      return const [];
    }
    final raw =
        await _channel.invokeMethod<List<dynamic>>(Channels.listPrinters);
    if (raw == null) return const [];
    return raw
        .map((item) {
          final map = Map<String, dynamic>.from(item as Map);
          final address =
              (map['address'] ?? map['serialNumber'] ?? '').toString();
          return ZebraAccessory(
            name: (map['name'] ?? '').toString(),
            address: address,
          );
        })
        .where((printer) => printer.address.isNotEmpty)
        .toList();
  }

  /// Opens the iOS Bluetooth accessory picker so the user can pair a Zebra printer.
  static Future<bool?> showAccessoryPicker() {
    return _channel.invokeMethod<bool>(Channels.showPicker);
  }

  static Future<bool> _ensureBluetoothPermission() async {
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted || status.isLimited;
    }

    // Advertise is not required to connect or print, and it is not in the
    // app manifest. Requiring it makes connect() fail on Android 12+.
    final result = await Future.wait([
      Permission.bluetooth.request(),
      Permission.bluetoothConnect.request(),
      Permission.bluetoothScan.request(),
    ]);
    return result.every((element) => element.isGranted || element.isLimited);
  }

  static Future<bool?> disconnect() async {
    return _channel.invokeMethod(Channels.discount);
  }
}
