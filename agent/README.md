# Zebra Printer

Small Windows app for the ZQ320. It looks for a printer on USB or Bluetooth, sends one test label, starts at Windows sign-in, and stays in the tray when minimized. Quitting asks for a password.

The quit password is the portal app configuration `printer_agent.close_password` (Settings → App configuration). The default until you change it is `shini`.

The app reads that value from `GET /api/printer-agent/close-password`. `portal.txt` next to the exe has two lines: the API base URL, then `printer_agent.access_key` from the same settings screen. Until both lines are filled in, the app keeps using `shini`.

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

The exe is `build\windows\x64\runner\Release\zebra_printer_agent.exe`. `portal.txt` is copied beside it.

Pair a Bluetooth printer in Windows settings first, or plug the printer in by USB so Windows shows it as a COM port or a Zebra printer. Open the app, press Find printers, then Test print.
