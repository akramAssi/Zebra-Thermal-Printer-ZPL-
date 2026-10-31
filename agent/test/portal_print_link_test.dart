import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/portal_print_link.dart';

void main() {
  test('a portal deep link points at the print file', () {
    final link = portalPrintLinkFrom(
      Uri.parse(
        'zebraprinter://print?token=abc&api=http%3A%2F%2F192.168.1.110%3A5174%2Fapi',
      ),
    );
    expect(link, isNotNull);
    expect(
      link!.fileUri.toString(),
      'http://192.168.1.110:5174/api/printer-agent/print-jobs/abc',
    );
  });

  test('a link without an http api is ignored', () {
    expect(
      portalPrintLinkFrom(Uri.parse('zebraprinter://print?token=abc&api=file')),
      isNull,
    );
    expect(portalPrintLinkFrom(Uri.parse('https://example.com/print')), isNull);
  });
}
