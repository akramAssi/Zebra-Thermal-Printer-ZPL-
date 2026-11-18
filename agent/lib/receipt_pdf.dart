import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// Same page the phone prints: 72 mm wide, no margin, 100% scale on the ZQ320.
const double receiptWidthMm = 72;

Future<Uint8List> pngToReceiptPdf(Uint8List pngBytes) async {
  final decoded = img.decodeImage(pngBytes);
  if (decoded == null || decoded.width < 1 || decoded.height < 1) {
    throw const FormatException('The receipt image could not be read.');
  }
  final width = receiptWidthMm * PdfPageFormat.mm;
  final height = width * decoded.height / decoded.width;
  final document = pw.Document();
  final picture = pw.MemoryImage(pngBytes);
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(width, height),
      margin: pw.EdgeInsets.zero,
      build: (context) {
        return pw.Image(
          picture,
          width: width,
          height: height,
          fit: pw.BoxFit.fill,
        );
      },
    ),
  );
  return document.save();
}

/// Short label whose black bars and side words sit on the page edge.
Future<Uint8List> testLabelPdf({
  required String title,
  required String detail,
  required String address,
}) async {
  final width = receiptWidthMm * PdfPageFormat.mm;
  final height = 28 * PdfPageFormat.mm;
  final bar = 3 * PdfPageFormat.mm;
  final document = pw.Document();
  document.addPage(
    pw.Page(
      pageFormat: PdfPageFormat(width, height),
      margin: pw.EdgeInsets.zero,
      build: (context) {
        return pw.Stack(
          children: [
            pw.Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: pw.Container(height: bar, color: PdfColors.black),
            ),
            pw.Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: pw.Container(height: bar, color: PdfColors.black),
            ),
            pw.Padding(
              padding: pw.EdgeInsets.only(top: bar + 3 * PdfPageFormat.mm),
              child: pw.Column(
                children: [
                  pw.Text(
                    title,
                    textAlign: pw.TextAlign.center,
                    style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold),
                  ),
                  pw.SizedBox(height: 2 * PdfPageFormat.mm),
                  pw.Text(
                    detail,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(fontSize: 11),
                  ),
                  pw.SizedBox(height: 1 * PdfPageFormat.mm),
                  pw.Text(
                    address,
                    textAlign: pw.TextAlign.center,
                    style: const pw.TextStyle(fontSize: 10),
                  ),
                  pw.SizedBox(height: 3 * PdfPageFormat.mm),
                  pw.Row(
                    mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
                    children: [
                      pw.Text('LEFT', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                      pw.Text('RIGHT', style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    ),
  );
  return document.save();
}
