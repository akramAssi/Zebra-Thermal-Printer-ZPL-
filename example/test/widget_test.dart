import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pdf/pdf.dart';
import 'package:zebra_bluetooth_printer_example/long_invoice.dart';

void main() {
  test(
    'a long invoice is one page and shorter than the printer maximum',
    () async {
      final invoice = await LongInvoice.build(
        lineCount: 40,
        directory: Directory.systemTemp,
      );

      expect(invoice.lineCount, 40);
      expect(invoice.bytes, isNotEmpty);
      expect(invoice.heightInches, greaterThan(8));
      expect(invoice.heightInches, lessThan(30));
      expect(invoice.heightInches, lessThan(38));
    },
  );

  test(
    'more lines make a taller invoice without jumping to the maximum',
    () async {
      final shorter = await LongInvoice.build(
        lineCount: 10,
        directory: Directory.systemTemp,
      );
      final longer = await LongInvoice.build(
        lineCount: 40,
        directory: Directory.systemTemp,
      );

      expect(longer.heightInches, greaterThan(shorter.heightInches + 5));
      expect(longer.heightInches, lessThan(38 * 1.0));
      expect(PdfPageFormat.inch, 72);
    },
  );
}
