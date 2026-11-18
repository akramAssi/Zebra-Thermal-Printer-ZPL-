# Zebra Printer

App for the ZQ320 on Windows, Android, and iOS. It looks for a printer, sends one test label, and asks for a password before it closes.

On Windows it starts at sign-in and stays in the tray when minimized. On Android it finds a Bluetooth or USB printer. On iOS it finds a printer paired with the Made-for-iPhone protocol `com.zebra.rawport`.

The quit password is the portal app configuration `printer_agent.close_password` (Settings → App configuration). The default until you change it is `shini`.

The app reads that value from `GET /api/printer-agent/close-password`. The portal address and `printer_agent.access_key` are built in (`lib/close_password.dart`), so phones and tablets need no extra file. Until the portal accepts that key, the app keeps using `shini`.

On Windows you can override them without rebuilding: put a `portal.txt` beside the exe with two lines, the API base URL, then the access key.

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

## Android

On a Mac or PC with the Android SDK:

```bash
cd agent
flutter pub get
flutter run -d android
```

A release apk:

```bash
flutter build apk
```

The apk is `build/app/outputs/flutter-apk/app-release.apk`. Install it on the device. With no printer connected, press Explore devices, then tap the Zebra to connect. You can also plug it in with USB. Closing the app asks for the portal password.

## iOS

Build on a Mac with Xcode. The printer must support the MFi protocol `com.zebra.rawport`.

```bash
cd agent
flutter pub get
flutter run -d ios
```

Open the app. With no printer connected, press Explore devices, choose the ZQ320, then tap it to connect. Closing asks for the portal password. iOS can still remove the app from the app switcher without that password.

## Label files from the portal

The app listens on port `17831`. The portal posts a PNG to `/print` and reads `/health`.

On Android and iOS the portal does not keep that socket open. iOS suspends the app about 30 seconds after Safari is in front, so the socket dies. On a phone, Print stores the PNG on the portal and opens `zebraprinter://print?token=...&api=...`. The app comes to the front, downloads the file, and prints it. Windows still posts straight to `http://127.0.0.1:17831`.

**Test portal file** posts a small PNG to this app the same way the portal does. A file from the portal appears in the Portal file box.

## USB driver

Bluetooth and a network printer do not need a Zebra driver. USB on Windows does. The Windows build copies `driver/zdesigner` next to the exe. On a PC without that driver, the app installs it first and Windows asks for administrator approval. Plug the printer in after that. Android USB and iOS Bluetooth do not use this driver.
