# What you need from the Zebra SDK to start

This plugin prints to a Link-OS Zebra (ZQ320, ZQ320 Plus, ZQ520, ZQ521). Only Android links the Zebra SDK. iOS and Windows send the same printer commands themselves. You do not download a Zebra SDK for those two platforms.

The Android binary is already in the repo. A new checkout can build as soon as Flutter and the Android SDK are installed.

## Already in this repo

| File                                         | What it is                                    |
| -------------------------------------------- | --------------------------------------------- |
| `android/libs/ZSDK_ANDROID_API.jar`          | Zebra Link-OS Multiplatform SDK **2.14.5198** |
| `android/libs/jackson-annotations-2.2.3.jar` | Required by that SDK jar                      |
| `android/libs/jackson-core-2.2.3.jar`        | Required by that SDK jar                      |
| `android/libs/jackson-databind-2.2.3.jar`    | Required by that SDK jar                      |

`android/build.gradle` loads every jar in `android/libs`. Keep these four files. Do not swap in a newer Link-OS jar unless you are upgrading the Java calls on purpose. The code is written against 2.14.5198.

If the jars are missing, download **Link-OS Multiplatform SDK 2.14.5198** for Android from Zebra and copy `ZSDK_ANDROID_API.jar` plus the three Jackson 2.2.3 jars into `android/libs/`.

## Classes this project uses

Stay inside this list when you add an Android feature. These are the SDK types the plugin already calls.

| Package                           | Classes                                                                                                               |
| --------------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `com.zebra.sdk.comm`              | `BluetoothConnection`, `TcpConnection`, `UsbConnection`, `Connection`, `ConnectionException`                          |
| `com.zebra.sdk.printer`           | `ZebraPrinterFactory`, `ZebraPrinter`, `ZebraPrinterLinkOs`, `PrinterStatus`, `PrinterLanguage`, `SGD`, `StorageInfo` |
| `com.zebra.sdk.printer.discovery` | `NetworkDiscoverer`, `UsbDiscoverer`, `DiscoveredPrinter`, `DiscoveryHandler`                                         |
| `com.zebra.sdk.graphics`          | `ZebraImageFactory`, `ZebraImageI`                                                                                    |

Calls already wired to Dart:

- Connect: `BluetoothConnection`, `TcpConnection` (port 9100), `UsbConnection`, then `ZebraPrinterFactory.getInstance`.
- Settings: `SGD.GET`, `SGD.SET`, `SGD.DO`.
- Status and tools: `getCurrentStatus`, `calibrate`, `printConfigurationLabel`, `restoreDefaults`, `reset`.
- Jobs: `write` for ZPL and CPCL, `sendFileContents` for PDF, `printImage` and `storeImage`.
- Files: `storeFileOnPrinter`, `getObjectFromPrinter`, `deleteFile`, `retrieveFileNames`, `getStorageInfo`.
- Formats: `printStoredFormat`.
- Find printers: `NetworkDiscoverer.findPrinters` / `subnetSearch`, `UsbDiscoverer.isZebraUsbDevice`.

Bluetooth discovery on Android does **not** use `BluetoothDiscoverer`. The plugin scans with the Android Bluetooth APIs and keeps imaging printers (`0x0680`), which is the same filter SDK 2.14 uses.

These SDK areas are not used. Leave them out unless a task asks for them: certificates, SNMP, Weblink, magstripe, smartcard, and firmware update.

## iOS: no Zebra SDK

Do not add `libZSDK_API.a` or `ZSDK_API.xcframework`.

iOS uses Apple `ExternalAccessory` and the Made-for-iPhone protocol `com.zebra.rawport`. Network printing is a TCP socket on port 9100. ZPL, CPCL, SGD, and `~HS` are written as bytes on that stream. The podspec already links `ExternalAccessory`.

Before the first iOS run, the app `Info.plist` needs:

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app prints to a paired Zebra printer.</string>
<key>UISupportedExternalAccessoryProtocols</key>
<array>
  <string>com.zebra.rawport</string>
</array>
```

Use a real iPhone. The simulator cannot see a paired printer. `address` is the accessory serial from discovery, not the MAC address.

## Windows: no Zebra SDK, but USB needs a driver

Do not add the Zebra .NET or C++ Link-OS SDK. The Android Link-OS download is not a Windows driver.

Windows sends ZPL itself: classic Bluetooth, TCP port 9100, a COM port, or a RAW printer queue. Compile this target on a Windows PC. A Mac can edit `windows/`, but it cannot build it.

| How the printer is connected         | Driver                                                                               |
| ------------------------------------ | ------------------------------------------------------------------------------------ |
| Bluetooth, already paired in Windows | None. Windows Bluetooth is enough.                                                   |
| Network, TCP port 9100               | None.                                                                                |
| USB                                  | Zebra Setup Utilities. That package includes Windows Printer Driver v10 (ZDesigner). |

Plug the USB cable in after the driver is installed. If the cable is first, Windows can leave the printer as an unknown device and the agent will not see it.

The agent checks for a Zebra or ZDesigner driver when it opens. If that driver is missing and `ZebraDriver.exe` was copied next to the app, the window shows **Install driver**. That button starts the installer and Windows asks for administrator approval.

Put the Zebra Setup Utilities installer here before the Windows build:

`agent/driver/ZebraDriver.exe`

The build copies it next to `zebra_printer_agent.exe`. There is no installer in the repo until that file is added.

## Start the example

```bash
cd example
flutter pub get
flutter run
```

Pair the printer first (Android or Windows Bluetooth settings, or the iOS accessory picker). On Android the first USB connect shows a permission prompt. Allow it, then connect again.

The button names on that screen match `ZebraSdk` in `lib/src/zebra_sdk.dart`. New printer work goes through that class, then the Android SDK calls in `android/src/main/java/.../SdkOperations.java`, or the same command bytes on iOS and Windows.
