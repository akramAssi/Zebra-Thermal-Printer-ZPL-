import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'mobile_home.dart';
import 'windows_home.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isWindows) {
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
  }

  runApp(const ZebraPrinterApp());
}

class ZebraPrinterApp extends StatelessWidget {
  const ZebraPrinterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: Platform.isIOS ? 'Printer Press' : 'Zebra Printer',
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
      // Windows runs the tray agent; phones and tablets run the portal queue app.
      home: Platform.isWindows
          ? const WindowsPrinterHome()
          : const MobilePrinterHome(),
    );
  }
}
