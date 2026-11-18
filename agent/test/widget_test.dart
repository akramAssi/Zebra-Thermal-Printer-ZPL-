import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/agent_log.dart';
import 'package:zebra_printer_agent/close_password.dart';
import 'package:zebra_printer_agent/print_queue.dart';
import 'package:zebra_printer_agent/printer_setup.dart';
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

  test('built-in portal settings are ready to call', () {
    const link = PortalLink(
      apiBaseUrl: kPortalApiBaseUrl,
      accessKey: kPortalAccessKey,
    );
    expect(link.canFetch, isTrue);
    expect(link.apiBaseUrl, 'https://online.shini.ps/roastery/api');
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

  test('portal reply message leaves the password out', () {
    expect(
      portalReplyMessage(
        '{"success":false,"message":"Printer agent access key is not configured"}',
      ),
      'Printer agent access key is not configured',
    );
    expect(
      portalReplyMessage('{"success":true,"data":{"password":"hidden"}}'),
      'no message',
    );
    expect(portalBodyHasPassword('{"data":{"password":"hidden"}}'), isTrue);
  });

  test('log file keeps only the last 24 hours', () {
    final now = DateTime(2026, 10, 21, 14);
    final fresh = now.subtract(const Duration(hours: 23)).toIso8601String();
    final stale = now.subtract(const Duration(hours: 25)).toIso8601String();
    final kept = retainRecentLogs([
      '$stale [zebra] old',
      '$fresh [zebra] recent',
      'not a timestamp',
      '',
    ], now);
    expect(kept, ['$fresh [zebra] recent']);
  });

  test('print queue lines keep the document name', () {
    const report = '''
job|3|Printing, Retained|Stock movement #3413
job|8|Normal|Zebra test

''';
    final jobs = parsePrintJobs(report);
    expect(jobs, hasLength(2));
    expect(jobs.first.id, 3);
    expect(jobs.first.status, 'Printing, Retained');
    expect(jobs.first.title, 'Stock movement #3413');
    expect(jobs.last.title, 'Zebra test');
    expect(parsePrintJobs(''), isEmpty);
    expect(parsePrintJobs('job|nope|Normal|Skipped'), isEmpty);
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
