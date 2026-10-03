import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// A sales invoice that is long because it has many lines.
/// The page is only as tall as those lines. It is not stretched to the
/// printer maximum (38 inches on ZQ520 / ZQ521, 90 inches on ZQ320).
class LongInvoice {
  const LongInvoice({
    required this.bytes,
    required this.filePath,
    required this.lineCount,
    required this.heightInches,
  });

  final Uint8List bytes;
  final String filePath;
  final int lineCount;
  final double heightInches;

  static const double widthMm = 72;
  static const double rowHeight = 22;

  static Future<LongInvoice> build({
    int lineCount = 40,
    Directory? directory,
  }) async {
    final lines = lineCount < 1 ? 1 : lineCount;
    final doc = pw.Document();
    final page = pw.Page(
      pageFormat: const PdfPageFormat(
        widthMm * PdfPageFormat.mm,
        double.infinity,
      ),
      margin: const pw.EdgeInsets.all(8),
      build: (context) {
        return pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            pw.Text(
              'Shini Sons',
              // FontWeight cannot be const in pdf 3.13.
              // ignore: prefer_const_constructors
              style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
              textAlign: pw.TextAlign.center,
            ),
            pw.SizedBox(height: 4),
            pw.Text('Invoice 10482', style: const pw.TextStyle(fontSize: 11)),
            pw.Text(
              'Customer  Al Amal Market',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.Text(
              'Date  30 Sep 2026',
              style: const pw.TextStyle(fontSize: 10),
            ),
            pw.SizedBox(height: 8),
            pw.Row(
              children: [
                pw.Expanded(flex: 6, child: pw.Text('Item', style: _header)),
                pw.Expanded(
                  flex: 2,
                  child: pw.Text(
                    'Qty',
                    style: _header,
                    textAlign: pw.TextAlign.right,
                  ),
                ),
                pw.Expanded(
                  flex: 3,
                  child: pw.Text(
                    'Total',
                    style: _header,
                    textAlign: pw.TextAlign.right,
                  ),
                ),
              ],
            ),
            pw.Divider(thickness: 0.6),
            for (var index = 0; index < lines; index++)
              pw.Container(
                height: rowHeight,
                alignment: pw.Alignment.centerLeft,
                decoration: const pw.BoxDecoration(
                  border: pw.Border(bottom: pw.BorderSide(width: 0.3)),
                ),
                child: pw.Row(
                  children: [
                    pw.Expanded(
                      flex: 6,
                      child: pw.Text(
                        'Item ${index + 1}  Rice 5kg',
                        style: const pw.TextStyle(fontSize: 9),
                      ),
                    ),
                    pw.Expanded(
                      flex: 2,
                      child: pw.Text(
                        '${(index % 4) + 1}',
                        style: const pw.TextStyle(fontSize: 9),
                        textAlign: pw.TextAlign.right,
                      ),
                    ),
                    pw.Expanded(
                      flex: 3,
                      child: pw.Text(
                        ((index + 1) * 3.25).toStringAsFixed(2),
                        style: const pw.TextStyle(fontSize: 9),
                        textAlign: pw.TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            pw.SizedBox(height: 8),
            pw.Text('Lines  $lines', style: const pw.TextStyle(fontSize: 10)),
            pw.Text(
              'Total  ${(lines * 8.5).toStringAsFixed(2)}',
              // ignore: prefer_const_constructors
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
          ],
        );
      },
    );
    doc.addPage(page);
    final bytes = await doc.save();
    final height = page.pageFormat.height / PdfPageFormat.inch;
    final dir = directory ?? await getTemporaryDirectory();
    final file = File('${dir.path}/long_invoice.pdf');
    await file.writeAsBytes(bytes, flush: true);
    return LongInvoice(
      bytes: bytes,
      filePath: file.path,
      lineCount: lines,
      heightInches: height,
    );
  }
}

// ignore: prefer_const_constructors
final _header = pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold);
