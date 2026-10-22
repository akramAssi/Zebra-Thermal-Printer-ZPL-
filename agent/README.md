# Zebra Printer

Small Windows app for the ZQ320. It looks for a printer on USB or Bluetooth, sends one test label, starts at Windows sign-in, and stays in the tray when minimized. Quitting asks for a password.

The quit password is the portal app configuration `printer_agent.close_password` (Settings → App configuration). The default until you change it is `shini`.

The app reads that value from `GET /api/printer-agent/close-password`. The portal address and `printer_agent.access_key` are set in `lib/close_password.dart`. Until the portal accepts that key, the app keeps using `shini`.

## Build on Windows

Copy this whole `Zebra-Thermal-Printer-ZPL-` folder to the Windows PC. Install Flutter there, then:

```bash
cd agent
flutter pub get
flutter run -d windows
```

A release build:

```bash
flutter build windows
```

The exe is `build\windows\x64\runner\Release\zebra_printer_agent.exe`. Copy that whole Release folder.

Pair a Bluetooth printer in Windows settings first, or plug the printer in by USB so Windows shows it as a COM port or a Zebra printer. Open the app, press Find printers, then Test print.

## USB driver

Bluetooth and a network printer do not need a Zebra driver. USB does. The Windows build copies `driver/zdesigner` next to the exe. On a PC without that driver, the app installs it first and Windows asks for administrator approval. Plug the printer in after that.
