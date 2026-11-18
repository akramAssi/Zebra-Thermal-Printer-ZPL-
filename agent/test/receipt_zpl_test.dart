import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:zebra_printer_agent/receipt_zpl.dart';

void main() {
  test('a black receipt becomes a black ZPL graphic', () {
    final image = img.Image(width: rollPrintWidthDots, height: 8);
    img.fill(image, color: img.ColorRgb8(0, 0, 0));
    final zpl = pngToReceiptZpl(img.encodePng(image));
    expect(zpl, contains('device.languages'));
    expect(zpl, contains('continuous'));
    expect(zpl, contains('^PW576'));
    expect(zpl, contains('^MNN'));
    expect(zpl, contains('^GFA,576,576,72,'));
    expect(zpl, contains('FF'));
    expect(zpl, isNot(contains('00')));
  });

  test('a white receipt stays blank on the thermal head', () {
    final image = img.Image(width: rollPrintWidthDots, height: 2);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final zpl = imageToReceiptZpl(image);
    expect(zpl, contains('^GFA,144,144,72,'));
    expect(zpl, contains('00'));
    expect(zpl, isNot(contains('FF')));
  });

  test('a long receipt is split into strips', () {
    final image = img.Image(width: rollPrintWidthDots, height: 6);
    img.fill(image, color: img.ColorRgb8(255, 255, 255));
    final zpl = imageToReceiptZpl(image, maxStripRows: 4);
    expect('^XA'.allMatches(zpl), hasLength(2));
  });
}
