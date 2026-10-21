import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/close_password.dart';
import 'package:zebra_printer_agent/printer_setup.dart';
import 'package:zebra_printer_agent/wifi_setup.dart';
import 'package:zebra_printer_agent/windows_driver.dart';

void main() {
  test('comments and blank lines are ignored', () {
    const file = '''
# portal API
https://online.shini.ps/roastery/api

# access key
warehouse-key
''';
    final link = portalLinkFrom(file);
    expect(link.apiBaseUrl, 'https://online.shini.ps/roastery/api');
    expect(link.accessKey, 'warehouse-key');
    expect(link.canFetch, isTrue);
  });

  test('missing access key does not call the portal', () {
    final link = portalLinkFrom('https://online.shini.ps/roastery/api\n');
    expect(link.canFetch, isFalse);
    expect(portalLinkFrom(null).canFetch, isFalse);
    expect(portalLinkFrom('# only a comment\n').canFetch, isFalse);
  });

  test('portal body replaces the password', () {
    const body = '{"success":true,"data":{"password":" warehouse "}}';
    expect(closePasswordFromPortalBody(body), 'warehouse');
  });

  test('a Zebra or ZDesigner driver counts as installed', () {
    expect(driverInstalledFromReport('ZDesigner ZQ320'), isTrue);
    expect(
      driverInstalledFromReport('Provider Name: Zebra Technologies'),
      isTrue,
    );
    expect(driverInstalledFromReport('Microsoft Print To PDF'), isFalse);
    expect(driverInstalledFromReport(''), isFalse);
  });

  test('printer report says when the USB queue is ready', () {
    const report = '''
usb=1
queue=1
driver=1
package=1
port_ready=1
protected=0
queue_name=ZDesigner ZQ320 Plus
device_name=ZTC ZQ320 Plus
port=USB002
''';
    final machine = parsePrinterMachine(report);
    expect(machine.usbConnected, isTrue);
    expect(machine.queueReady, isTrue);
    expect(machine.protectedPrint, isFalse);
    expect(machine.queueName, 'ZDesigner ZQ320 Plus');
    expect(machine.port, 'USB002');
    expect(printerLinkFrom(machine).canPrint, isTrue);
    expect(printerLinkFrom(machine).label, 'Ready');
  });

  test('a Windows queue is not connected when the USB cable is unplugged', () {
    const report = '''
usb=0
queue=1
printer_status=Normal
queue_name=ZDesigner ZQ320 Plus
''';
    final link = printerLinkFrom(parsePrinterMachine(report));
    expect(link.canPrint, isFalse);
    expect(link.cableConnected, isFalse);
    expect(link.label, 'Not connected');
    expect(link.showPrinter, isTrue);
  });

  test('paper out stays visible while the cable is connected', () {
    const report = '''
usb=1
queue=1
printer_status=PaperOut
queue_name=ZDesigner ZQ320 Plus
''';
    final link = printerLinkFrom(parsePrinterMachine(report));
    expect(link.canPrint, isFalse);
    expect(link.cableConnected, isTrue);
    expect(link.label, 'Out of paper');
  });

  test('setup report keeps the outcome', () {
    expect(
      parseSetupReport('result=need_reboot\r\ndetail=USB002').outcome,
      SetupOutcome.needReboot,
    );
    expect(parseSetupReport('result=cancelled').outcome, SetupOutcome.cancelled);
    expect(parseSetupReport('').outcome, SetupOutcome.failed);
  });

  test('wifi scan keeps the current network and the saved password', () {
    const report = '''
current=Shop WiFi
password=store-pass
network=Shop WiFi
network=Guest
''';
    final scan = parseWifiScan(report);
    expect(scan.current, 'Shop WiFi');
    expect(scan.password, 'store-pass');
    expect(scan.networks, ['Shop WiFi', 'Guest']);
  });

  test('wifi password becomes the 64 digit printer key', () {
    expect(
      wpaPskHex('password', 'IEEE'),
      'f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e',
    );
  });

  test('bad portal body keeps the current password', () {
    expect(closePasswordFromPortalBody('nope', fallback: 'kept'), 'kept');
    expect(
      closePasswordFromPortalBody(
        '{"success":true,"data":{"password":"  "}}',
        fallback: 'kept',
      ),
      'kept',
    );
  });
}
