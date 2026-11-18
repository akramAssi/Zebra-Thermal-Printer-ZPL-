import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zebra_printer_agent/receipt_pdf.dart';

void main() {
  test('a receipt png becomes a 72 mm pdf with no page margin', () async {
    final image = img.Image(width: 576, height: 40);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));
    final pdf = await pngToReceiptPdf(img.encodePng(image));
    final text = String.fromCharCodes(pdf);
    expect(text.startsWith('%PDF'), isTrue);
    expect(text, contains('/MediaBox'));
  });
}
