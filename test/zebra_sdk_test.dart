import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_bluetooth_printer/zebra_bluetooth_printer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zebra_bluetooth_printer');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('format fields match ^FN numbers and names', () {
    const zpl = '^XA^FO10,10^A0N,30,30^FN1"Name"^FS^FO10,50^FN2^FS^XZ';
    final fields = ZebraFormat.fields(zpl);
    expect(fields.map((field) => field.number), [1, 2]);
    expect(fields.first.name, 'Name');
    expect(fields.last.name, '');
  });

  test('status map keeps the Link-OS flags', () {
    final status = ZebraPrinterStatus.fromMap({
      'isReadyToPrint': true,
      'isPaused': false,
      'isHeadOpen': false,
      'isPaperOut': true,
      'isRibbonOut': false,
      'isHeadCold': false,
      'isHeadTooHot': false,
      'isReceiveBufferFull': false,
      'isPartialFormatInProgress': false,
      'labelLengthInDots': 800,
      'numberOfFormatsInReceiveBuffer': 1,
      'labelsRemainingInBatch': 2,
      'printMode': 'TEAR_OFF',
    });
    expect(status.isReadyToPrint, isTrue);
    expect(status.isPaperOut, isTrue);
    expect(status.labelLengthInDots, 800);
    expect(status.numberOfFormatsInReceiveBuffer, 1);
    expect(status.printMode, 'TEAR_OFF');
  });

  test('getSetting sends an SDK call', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'SDK');
          final args = Map<String, dynamic>.from(call.arguments as Map);
          expect(args['op'], 'get');
          expect(args['setting'], 'device.languages');
          expect(args['address'], 'AA:BB');
          expect(args['transport'], 'bluetooth');
          return 'zpl';
        });

    expect(
      await ZebraSdk.getSetting('device.languages', address: 'AA:BB'),
      'zpl',
    );
  });

  test('network discovery maps printer rows', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          return [
            {
              'name': 'ZQ520',
              'address': '192.168.1.20',
              'transport': 'tcp',
              'port': 9100,
              'discovery': {'PRODUCT_NAME': 'ZQ520'},
            },
          ];
        });

    final printers = await ZebraSdk.discoverNetwork(subnet: '192.168.1.0');
    expect(printers.single.transport, ZebraTransport.tcp);
    expect(printers.single.address, '192.168.1.20');
    expect(printers.single.discoveryData['PRODUCT_NAME'], 'ZQ520');
  });
}
