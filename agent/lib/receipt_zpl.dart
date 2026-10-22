import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// ZQ320 maximum print width: 72 mm at 203 dpi (576 dots, one byte-aligned row).
const int rollPrintWidthDots = 576;

/// One receipt is one label, so the header stays above its lines.
const int receiptMaxStripRows = 20000;

const int _maxReceiptRows = 20000;

/// Turns a portal receipt image into ZPL the ZQ320 prints directly.
///
/// The printer is switched to ZPL and continuous media first, so a roll with
/// no gaps is not rejected. Graphics are sent in strips so a long receipt
/// still fits in one job.
String pngToReceiptZpl(Uint8List pngBytes) {
  final decoded = img.decodeImage(pngBytes);
  if (decoded == null) {
    throw const FormatException('The receipt image could not be read.');
  }
  return imageToReceiptZpl(decoded);
}

String imageToReceiptZpl(
  img.Image source, {
  int maxStripRows = receiptMaxStripRows,
}) {
  final fitted = _fitWidth(source);
  if (fitted.height > _maxReceiptRows) {
    throw const FormatException('The receipt is too long.');
  }
  final strips = _strips(fitted, math.max(1, maxStripRows));
  final labels = strips.map(_label).join('\r\n');
  return '! U1 setvar "device.languages" "zpl"\r\n'
      '! U1 setvar "ezpl.media_type" "continuous"\r\n'
      '! U1 setvar "ezpl.print_width" "$rollPrintWidthDots"\r\n'
      '$labels\r\n';
}

img.Image _fitWidth(img.Image source) {
  if (source.width == rollPrintWidthDots) return source;
  final height = math.max(
    1,
    (source.height * rollPrintWidthDots / source.width).round(),
  );
  return img.copyResize(
    source,
    width: rollPrintWidthDots,
    height: height,
    interpolation: img.Interpolation.average,
  );
}

List<img.Image> _strips(img.Image image, int maxRows) {
  if (image.height <= maxRows) return [image];
  final strips = <img.Image>[];
  for (var top = 0; top < image.height; top += maxRows) {
    final rows = math.min(maxRows, image.height - top);
    strips.add(
      img.copyCrop(image, x: 0, y: top, width: image.width, height: rows),
    );
  }
  return strips;
}

String _label(img.Image strip) {
  return '^XA'
      '^LH0,0'
      '^LS0'
      '^MNN'
      '^PW${strip.width}'
      '^LL${strip.height}'
      '^FO0,0${_gfa(strip)}^FS'
      '^XZ';
}

String _gfa(img.Image image) {
  final rowBytes = (image.width + 7) ~/ 8;
  final total = rowBytes * image.height;
  final hex = StringBuffer();
  for (var y = 0; y < image.height; y++) {
    var byte = 0;
    var bit = 0;
    for (var x = 0; x < image.width; x++) {
      if (_isBlack(image.getPixel(x, y))) {
        byte |= 1 << (7 - bit);
      }
      bit++;
      if (bit == 8) {
        hex.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
        byte = 0;
        bit = 0;
      }
    }
    if (bit != 0) {
      hex.write(byte.toRadixString(16).padLeft(2, '0').toUpperCase());
    }
  }
  return '^GFA,$total,$total,$rowBytes,$hex';
}

/// Treats gray text edges as black so a thermal head still prints them.
bool _isBlack(img.Pixel pixel) {
  var luminance = pixel.luminance.toDouble();
  if (luminance > 1) luminance /= 255;
  return luminance < 0.82;
}
