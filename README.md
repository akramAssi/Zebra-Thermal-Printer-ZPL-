# zebra_bluetooth_printer

Flutter access to the Zebra Link-OS SDK on Android and iOS.

Android calls the SDK in `android/libs/ZSDK_ANDROID_API.jar`: discovery, `SGD`, printer status, ZPL, CPCL, PDF Direct, graphics, files, stored formats, and the printer tools. iOS sends those same printer commands over the Made-for-iPhone raw port `com.zebra.rawport`, or over TCP port 9100. USB is Android only.

The example app runs every use case. Open `example/` and press the button with the same name as the API.

## Install

```yaml
dependencies:
  zebra_bluetooth_printer:
    path: ../Zebra-Thermal-Printer-ZPL-
```

```dart
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';
```

`ZebraSdk` is the full API. `ZebraBluetoothPrinter.print`, `printPdf`, and `printPdfs` stay as they are: each one connects, sends, and disconnects.

`ZebraSdk.connect` keeps the session open until `ZebraSdk.disconnect`. Pass `address` again only when you want a different printer.

## Android setup

The plugin manifest already requests Bluetooth, internet, and USB host (`required=false`).

On Android 12 and newer the app must also be allowed to scan and connect. The plugin requests `bluetoothScan` and `bluetoothConnect` before a Bluetooth call.

A network printer is a TCP socket, usually port 9100. The phone and the printer have to be on the same network.

USB asks for permission the first time. Allow the system prompt, then connect again.

## iOS setup

Add this to the app `Info.plist`. The protocol is required or iOS will not see the printer.

```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>This app prints to a paired Zebra printer.</string>
<key>UISupportedExternalAccessoryProtocols</key>
<array>
  <string>com.zebra.rawport</string>
</array>
```

The background mode `external-accessory` is required if the printer should stay connected while the app is not on screen.

iOS does not connect by MAC address. `address` is the accessory serial number from discovery. If the list is empty, call `ZebraBluetoothPrinter.showAccessoryPicker()` and pair the printer, then discover again.

A network printer uses the printer IP. iOS has no Link-OS discovery packet, so pass a subnet such as `192.168.1.0` and the plugin probes port 9100.

## Transports

| Transport                  | Android address       | iOS address           |
| -------------------------- | --------------------- | --------------------- |
| `ZebraTransport.bluetooth` | MAC address           | Accessory serial      |
| `ZebraTransport.tcp`       | IP address, port 9100 | IP address, port 9100 |
| `ZebraTransport.usb`       | USB device name       | Not available         |

## Find a printer

```dart
final bluetooth = await ZebraSdk.discoverBluetooth();
final network = await ZebraSdk.discoverNetwork(subnet: '192.168.1.0');
final usb = await ZebraSdk.discoverUsb(); // Android

await ZebraBluetoothPrinter.showAccessoryPicker(); // iOS pairing
```

`discoverBluetooth` on Android returns paired printers and printers found by a classic scan. On iOS it returns accessories that are already paired.

## Connect

```dart
await ZebraSdk.connect(
  address: printer.address,
  transport: printer.transport,
  port: printer.port,
);

final open = await ZebraSdk.isConnected();
await ZebraSdk.disconnect();
```

Leave `address` empty on later calls to reuse the open session.

Progress messages (`Connecting...`, `Connected`, `Printed`, failures) arrive on `ZebraBluetoothPrinter.eventChannel`.

## Status and settings

```dart
final status = await ZebraSdk.status(address: address);
if (status.isHeadOpen || status.isPaperOut || !status.isReadyToPrint) {
  // do not send a job
}

final info = await ZebraSdk.printerInfo(address: address);
final language = await ZebraSdk.getSetting('device.languages', address: address);
await ZebraSdk.setSetting('print.tone', '15', address: address);
await ZebraSdk.setSetting('ezpl.media_type', 'continuous', address: address);

final counts = await ZebraSdk.odometer(address: address);
final drives = await ZebraSdk.storageInfo(address: address);

await ZebraSdk.setClock(
  date: '09-30-2026',
  time: '13:05:00',
  address: address,
);
```

`status` is Link-OS `PrinterStatus` on Android and the `~HS` reply on iOS. `printerInfo` reads the SGD keys for model, firmware, language, media, darkness, speed, battery, and IP.

`ZebraSdk.doCommand('file.dir', value: 'E:')` is `SGD.DO`.

Useful SGD names:

| Setting                      | What it does                         |
| ---------------------------- | ------------------------------------ |
| `device.languages`           | `zpl`, `cpcl`, or `line_print`       |
| `device.host_identification` | Model, such as `ZQ520` or `ZQ320`    |
| `ezpl.media_type`            | `continuous`, `gap/notch`, or `mark` |
| `ezpl.print_width`           | Width in dots                        |
| `print.tone`                 | Darkness                             |
| `media.speed`                | Print speed                          |
| `power.percent_full`         | Battery on mobile printers           |

## Print

```dart
await ZebraSdk.printZpl('^XA^FO20,20^A0N,40,40^FDHello^FS^XZ', address: address);

await ZebraSdk.printCpcl(
  '! 0 200 200 210 1\r\nTEXT 4 0 30 40 CPCL\r\nPRINT\r\n',
  address: address,
);

await ZebraSdk.printRaw(bytes, address: address);
await ZebraSdk.printPdf('/path/invoice.pdf', address: address);
await ZebraSdk.printPdfs(['/path/page1.pdf', '/path/page2.pdf'], address: address);
await ZebraSdk.printImage('/path/logo.png', x: 20, y: 20, address: address);
await ZebraSdk.sendFile('/path/labels.zpl', address: address);
```

PDF printing turns on Zebra PDF Direct, prints at 100% scale on ZQ520, ZQ521, ZQ320, and ZQ320 Plus, and uses continuous media for that job so a long receipt is not cut into labels. The previous media type is restored after the printer accepts the file. Several PDFs of one invoice go out on the same connection.

`printImage` uses `GraphicsUtil` on Android. iOS converts the PNG or JPEG to a ZPL `^GFA` image. Width and height are dots. `0` keeps the source size.

`sendFile` writes the file to the print channel. It does not save it on the printer drive. `storeFile` does.

CPCL is sent after `device.languages` is set to `cpcl`. A ZPL-only printer will not print that job.

## Tools

```dart
await ZebraSdk.feed(address: address);
await ZebraSdk.calibrate(address: address);
await ZebraSdk.printConfigurationLabel(address: address);
await ZebraSdk.printNetworkConfigurationLabel(address: address);
await ZebraSdk.printDirectoryLabel(address: address);
```

`restoreDefaults` sends `^JUF` and clears printer settings. `reset` sends `~JR` and the printer reboots. Firmware update is not exposed.

## Files and stored formats

```dart
final names = await ZebraSdk.listFiles(drive: 'E:', address: address);

await ZebraSdk.storeFile('E:LOGO.GRF', '/path/logo.grf', address: address);
await ZebraSdk.storeImage('E:LOGO.GRF', '/path/logo.png', address: address);

final bytes = await ZebraSdk.retrieveFile('E:DEMO.ZPL', address: address);
await ZebraSdk.deleteFile('E:DEMO.ZPL', address: address);
```

A stored format is ZPL saved on the printer with `^DF`. `ZebraFormat.fields` reads the `^FN` numbers, the same data `FormatUtil.getVariableFields` returns.

```dart
const format = '^XA^DFE:DEMO.ZPL^FS'
    '^FO20,20^A0N,30,30^FN1"Name"^FS'
    '^FO20,60^A0N,30,30^FN2"Price"^FS'
    '^XZ';

final fields = ZebraFormat.fields(format); // FN1 Name, FN2 Price
await ZebraSdk.printZpl(format, address: address);
await ZebraSdk.printStoredFormat(
  'E:DEMO.ZPL',
  {1: 'Shini', 2: '12.50'},
  address: address,
);
```

Android prints that with `FormatUtil.printStoredFormat`. iOS sends `^XA^XFE:DEMO.ZPL^FS^FN1^FD...^FS^XZ`.

## Errors

| Code  | Meaning                                                                  |
| ----- | ------------------------------------------------------------------------ |
| `001` | The printer refused the job. Head open, paper out, or paused.            |
| `004` | Bluetooth permission, or the connection failed.                          |
| `100` | The operation is unknown, the file is missing, or USB was called on iOS. |

Listen to `ZebraBluetoothPrinter.eventChannel` for the same text the printer flow shows the user.

## What differs by platform

| Operation             | Android                             | iOS                                     |
| --------------------- | ----------------------------------- | --------------------------------------- |
| Bluetooth discovery   | SDK scan plus paired devices        | Paired MFi accessories                  |
| Pairing UI            | System Bluetooth settings           | `showAccessoryPicker`                   |
| Network discovery     | `NetworkDiscoverer`                 | Port 9100 probe of the subnet you pass  |
| USB                   | `UsbDiscoverer` and `UsbConnection` | Not available                           |
| Status                | `PrinterStatus`                     | `~HS`                                   |
| SGD, ZPL, CPCL, tools | SDK                                 | The same commands on the raw port       |
| PDF                   | `sendFileContents`                  | Raw PDF bytes after `apl.settings`      |
| Image                 | `GraphicsUtil`                      | ZPL `^GFA`                              |
| Files and formats     | `FileUtil` and `FormatUtil`         | `file.dir`, `file.delete`, `^DF`, `^XF` |

## Example

```bash
cd example
flutter run
```

The screen is the use-case list: discovery, session, status, SGD, ZPL, CPCL, raw, PDF, image, feed, calibrate, configuration labels, files, and stored formats. The log at the bottom is the printer reply.

On iOS, create the example iOS project once if it is not there:

```bash
cd example
flutter create . --platforms=ios
```

Then add the `Info.plist` keys from the iOS setup section.
