import 'dart:io';

import 'package:permission_handler/permission_handler.dart';

Future<bool> requestBluetoothPermission() async {
  if (Platform.isIOS) {
    final status = await Permission.bluetooth.request();
    return status.isGranted || status.isLimited;
  }
  if (!Platform.isAndroid) return true;

  // Advertise is not required to connect or print, and it is not in the
  // app manifest. Requiring it makes connect() fail on Android 12+.
  final result = await Future.wait([
    Permission.bluetooth.request(),
    Permission.bluetoothConnect.request(),
    Permission.bluetoothScan.request(),
  ]);
  return result.every((element) => element.isGranted || element.isLimited);
}
