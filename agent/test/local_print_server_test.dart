import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/local_print_server.dart';

void main() {
  test('health and print stay on this computer', () async {
    Uint8List? received;
    var ready = true;
    final server = await LocalPrintServer.start(
      printerReady: () => ready,
      printerName: () => 'ZQ320',
      printPng: (png) async {
        received = png;
      },
      log: (_) {},
    );
    addTearDown(server.close);

    final client = HttpClient();
    addTearDown(client.close);

    final healthRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:${LocalPrintServer.port}/health'),
    );
    final health = await healthRequest.close();
    final healthBody = await health.transform(utf8.decoder).join();
    expect(health.statusCode, 200);
    expect(healthBody, contains('"printerReady":true'));
    expect(healthBody, contains('ZQ320'));
    expect(health.headers.value('Access-Control-Allow-Private-Network'), 'true');

    ready = false;
    final blocked = await client.postUrl(
      Uri.parse('http://127.0.0.1:${LocalPrintServer.port}/print'),
    );
    blocked.headers.contentType = ContentType('image', 'png');
    blocked.add([1, 2, 3]);
    final blockedResponse = await blocked.close();
    await blockedResponse.drain<void>();
    expect(blockedResponse.statusCode, 409);
    expect(received, isNull);

    ready = true;
    final printed = await client.postUrl(
      Uri.parse('http://127.0.0.1:${LocalPrintServer.port}/print'),
    );
    printed.headers.contentType = ContentType('image', 'png');
    printed.add([9, 8, 7]);
    final printedResponse = await printed.close();
    await printedResponse.drain<void>();
    expect(printedResponse.statusCode, 200);
    expect(received, [9, 8, 7]);
  });
}
