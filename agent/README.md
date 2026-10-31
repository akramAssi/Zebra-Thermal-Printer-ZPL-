# Zebra Printer

App for the ZQ320 on Windows, Android, and iOS. It looks for a printer, sends one test label, and asks for a password before it closes.

On Windows it starts at sign-in and stays in the tray when minimized. On Android it finds a Bluetooth or USB printer. On iOS it finds a printer paired with the Made-for-iPhone protocol `com.zebra.rawport`.

The quit password is the portal app configuration `printer_agent.close_password` (Settings → App configuration). The default until you change it is `shini`.

The app reads that value from `GET /api/printer-agent/close-password`. `portal.txt` has two lines: the API base URL, then `printer_agent.access_key` from the same settings screen. Until both lines are filled in, the app keeps using `shini`.

On Windows, the copy beside the exe is the one that is used, so you can change it without rebuilding. On Android and iOS that same file is packed inside the installed app, so the password still comes from the portal after the app is installed. Change `portal.txt`, then build again, to point a phone or tablet at a different portal.

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

On Windows, Bluetooth does not need a Zebra driver. USB does. Install Zebra Setup Utilities before the USB cable is plugged in. That package includes the ZDesigner printer driver. Android USB and iOS Bluetooth do not use this installer.

Save that installer as `driver/ZebraDriver.exe` in this `agent` folder before building. The build copies it next to the exe. If Windows has no Zebra driver, the app shows **Install driver**. Windows asks for administrator approval, then the installer runs.
