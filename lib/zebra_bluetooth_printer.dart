import 'dart:async';
import 'dart:developer';

import 'package:flutter/services.dart';

class ZebraBluetoothPrinter {
  static const MethodChannel _channel =
      MethodChannel('zebra_bluetooth_printer');

  static const EventChannel eventChannel =
      EventChannel('zebra_bluetooth_printer_stream');
  static Stream? _printStream;

  static Future<int?> get platformVersion async {
    final int? version = await _channel.invokeMethod('getPlatformVersion');
    return version;
  }

  static Future<dynamic> print(String zpl, String macAddress) async {

    return _channel.invokeMethod('print', [zpl, macAddress]).onError(
        (error, stackTrace) => log(stackTrace.toString()));

  }

  static Future<String?> checkConnection(String macAddress) async {
    final String? version =
        await _channel.invokeMethod('checkConnection', macAddress);
    return version;
  }

  static Stream? printStream() {
    _printStream ??= eventChannel.receiveBroadcastStream();

    return _printStream;
  }

  static Future<bool?> connect(String macAddress) async {
    return _channel.invokeMethod('connect', macAddress);
  }
  static Future<bool?> disconnect() async {
    return _channel.invokeMethod('disconnect');
  }
}
