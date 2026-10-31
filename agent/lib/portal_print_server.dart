import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Same port the portal uses in `localPrinterAgent.ts`.
const int kPortalPrintPort = 17831;

/// 1×1 PNG. The in-app test posts this the same way the portal posts a label.
const List<int> kPortalTestPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x02,
  0x00,
  0x00,
  0x00,
  0x90,
  0x77,
  0x53,
  0xDE,
  0x00,
  0x00,
  0x00,
  0x0C,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0x00,
  0x00,
  0x03,
  0x01,
  0x01,
  0x00,
  0xC9,
  0xFE,
  0x92,
  0xEF,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

class PortalPrintResult {
  const PortalPrintResult({required this.printed, this.message = ''});

  final bool printed;
  final String message;
}

bool looksLikePng(List<int> bytes) {
  if (bytes.length < 8) return false;
  return bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47;
}

/// Addresses a browser can use. Loopback is this device. The others are for a
/// portal open on another computer on the same Wi-Fi.
Future<List<String>> portalListenAddresses(int port) async {
  final urls = <String>['http://127.0.0.1:$port'];
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLinkLocal: false,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        if (address.isLoopback) continue;
        final url = 'http://${address.address}:$port';
        if (!urls.contains(url)) urls.add(url);
      }
    }
  } catch (_) {}
  return urls;
}

/// Accepts the portal's `GET /health` and `POST /print` (PNG body).
class PortalPrintServer {
  PortalPrintServer({required this.onFile});

  final Future<PortalPrintResult> Function(List<int> png) onFile;

  HttpServer? _server;
  var printerReady = false;
  var printerName = '';
  var busy = false;

  int get port => _server?.port ?? kPortalPrintPort;

  Future<void> start({int port = kPortalPrintPort}) async {
    final server = await HttpServer.bind(
      InternetAddress.anyIPv4,
      port,
      shared: true,
    );
    _server = server;
    server.listen(_handle);
  }

  Future<void> close() async {
    final server = _server;
    _server = null;
    await server?.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    _cors(request.response);
    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      final path = request.uri.path;
      if (request.method == 'GET' && path == '/health') {
        await _json(request.response, HttpStatus.ok, {
          'printerReady': printerReady && !busy,
          'printer': printerName,
        });
        return;
      }
      if (request.method == 'POST' && path == '/print') {
        await _print(request);
        return;
      }
      await _json(request.response, HttpStatus.notFound, {'code': 'failed'});
    } catch (_) {
      await _json(request.response, HttpStatus.internalServerError, {
        'code': 'failed',
      });
    }
  }

  Future<void> _print(HttpRequest request) async {
    if (busy) {
      await _json(request.response, HttpStatus.conflict, {'code': 'busy'});
      return;
    }
    if (!printerReady) {
      await _json(request.response, HttpStatus.conflict, {'code': 'not_ready'});
      return;
    }
    final bytes = await _readBody(request);
    if (!looksLikePng(bytes)) {
      await _json(request.response, HttpStatus.badRequest, {'code': 'failed'});
      return;
    }
    busy = true;
    try {
      final result = await onFile(bytes);
      await _json(request.response, HttpStatus.ok, {
        'accepted': true,
        'printed': result.printed,
        'message': result.message,
      });
    } catch (_) {
      await _json(request.response, HttpStatus.internalServerError, {
        'code': 'failed',
      });
    } finally {
      busy = false;
    }
  }

  Future<List<int>> _readBody(HttpRequest request) async {
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > 12 * 1024 * 1024) break;
    }
    return builder.takeBytes();
  }

  void _cors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    response.headers.set('Access-Control-Allow-Private-Network', 'true');
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object?> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
