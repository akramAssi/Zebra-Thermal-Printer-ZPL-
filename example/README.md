# Zebra SDK example

Run every plugin use case against a Zebra printer.

```bash
cd example
flutter run
```

On iOS, if this folder has no `ios/` project:

```bash
flutter create . --platforms=ios
```

Add `com.zebra.rawport` under `UISupportedExternalAccessoryProtocols` in `Info.plist`, then run again.

## What each button does

1. **Bluetooth printers** — `ZebraSdk.discoverBluetooth`. Fills the address with the first printer.
2. **iOS accessory picker** — pairs a Made-for-iPhone Zebra. Discover again after pairing.
3. **Network printers** — `discoverNetwork` on the subnet field. Android uses Link-OS discovery. iOS probes port 9100.
4. **USB printers** — Android `discoverUsb`. Allow the permission prompt, then connect.
5. **Connect / Is connected / Disconnect** — one session for the calls below.
6. **Status** — head, paper, ribbon, pause, and buffer.
7. **Printer info** — model, firmware, language, media, darkness, speed, battery, IP.
8. **Odometer / Storage** — label counts and free space on E: and R:.
9. **SGD get / SGD set** — the setting and value fields. Defaults to `device.languages`.
10. **Set clock to now** — `rtc.date` and `rtc.time`.
11. **Print ZPL / CPCL / raw** — short built-in jobs.
12. **Print long invoice** — one PDF with many item lines (default 40). The page is only as tall as those lines. It is not stretched to 38 or 90 inches.
13. **Print PDF / image / store image** — uses the local file path field.
14. **Feed, calibrate, configuration labels** — printer tools.
15. **Restore defaults / Reset** — `^JUF` and `~JR`. These change or reboot the printer.
16. **List, send, store, retrieve, delete** — drive `E:`.
17. **Store a format, then print it** — writes `E:DEMO.ZPL` with `^FN1` and `^FN2`, then prints it with sample values.
18. **SGD do file.dir** — `SGD.DO`.

The log lists event-channel messages from the printer session.
