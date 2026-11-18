import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/portal_print_server.dart';

void main() {
  test('portal health and a png post reach the app', () async {
    List<int>? received;
    final server = PortalPrintServer(
      onFile: (png) async {
        received = png;
        return const PortalPrintResult(printed: false, message: 'saved');
      },
    );
    server.printerReady = true;
    server.printerName = 'ZQ320';
    await server.start(port: 0);
    addTearDown(server.close);

    final health = await _send(server.port, 'GET', '/health');
    expect(health.status, 200);
    expect(health.json['printerReady'], isTrue);
    expect(health.json['printer'], 'ZQ320');
    expect(health.cors, '*');

    final posted = await _send(
      server.port,
      'POST',
      '/print',
      body: kPortalTestPng,
      contentType: 'image/png',
    );
    expect(posted.status, 200);
    expect(posted.json['accepted'], isTrue);
    expect(received, kPortalTestPng);
  });

  test('a file is refused until a printer is ready', () async {
    final server = PortalPrintServer(
      onFile: (_) async => const PortalPrintResult(printed: false),
    );
    await server.start(port: 0);
    addTearDown(server.close);

    final posted = await _send(
      server.port,
      'POST',
      '/print',
      body: kPortalTestPng,
      contentType: 'image/png',
    );
    expect(posted.status, 409);
    expect(posted.json['code'], 'not_ready');
  });

  test('the browser preflight is allowed', () async {
    final server = PortalPrintServer(
      onFile: (_) async => const PortalPrintResult(printed: false),
    );
    await server.start(port: 0);
    addTearDown(server.close);

    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.openUrl(
      'OPTIONS',
      Uri.parse('http://127.0.0.1:${server.port}/print'),
    );
    request.headers.set('Access-Control-Request-Method', 'POST');
    request.headers.set('Access-Control-Request-Private-Network', 'true');
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 204);
    expect(response.headers.value('Access-Control-Allow-Origin'), '*');
    expect(
      response.headers.value('Access-Control-Allow-Private-Network'),
      'true',
    );
  });
}

class _Reply {
  const _Reply(this.status, this.json, this.cors);

  final int status;
  final Map<String, Object?> json;
  final String? cors;
}

Future<_Reply> _send(
  int port,
  String method,
  String path, {
  List<int>? body,
  String? contentType,
}) async {
  final client = HttpClient();
  try {
    final request = await client.openUrl(
      method,
      Uri.parse('http://127.0.0.1:$port$path'),
    );
    if (contentType != null) {
      request.headers.contentType = ContentType.parse(contentType);
    }
    if (body != null) request.add(body);
    final response = await request.close();
    final text = await utf8.decoder.bind(response).join();
    final decoded = jsonDecode(text);
    return _Reply(
      response.statusCode,
      decoded is Map<String, Object?>
          ? decoded
          : Map<String, Object?>.from(decoded as Map),
      response.headers.value('Access-Control-Allow-Origin'),
    );
  } finally {
    client.close(force: true);
  }
}
