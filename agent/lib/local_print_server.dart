import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Listens only on this computer so the portal can print a 72 mm roll
/// without the Windows print dialog.
class LocalPrintServer {
  LocalPrintServer._(
    this._server,
    this._printerReady,
    this._printerName,
    this._printPng,
    this._log,
  );

  static const int port = 17831;

  final HttpServer _server;
  final bool Function() _printerReady;
  final String Function() _printerName;
  final Future<void> Function(Uint8List png) _printPng;
  final void Function(String message) _log;
  var _busy = false;

  static Future<LocalPrintServer> start({
    required bool Function() printerReady,
    required String Function() printerName,
    required Future<void> Function(Uint8List png) printPng,
    void Function(String message)? log,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    final bridge = LocalPrintServer._(
      server,
      printerReady,
      printerName,
      printPng,
      log ?? _silent,
    );
    server.listen(bridge._handle, onError: (Object error) {
      bridge._log('Portal print connection failed: $error');
    });
    return bridge;
  }

  Future<void> close() => _server.close(force: true);

  static void _silent(String message) {}

  Future<void> _handle(HttpRequest request) async {
    _cors(request.response);
    try {
      if (request.method == 'OPTIONS') {
        request.response.statusCode = HttpStatus.noContent;
        await request.response.close();
        return;
      }
      if (request.method == 'GET' && request.uri.path == '/health') {
        await _json(request.response, HttpStatus.ok, {
          'ok': true,
          'printerReady': _printerReady(),
          'printer': _printerName(),
        });
        return;
      }
      if (request.method == 'POST' && request.uri.path == '/print') {
        await _print(request);
        return;
      }
      await _json(request.response, HttpStatus.notFound, {
        'ok': false,
        'code': 'not_found',
      });
    } catch (error) {
      _log('Portal print request failed: $error');
      try {
        await _json(request.response, HttpStatus.internalServerError, {
          'ok': false,
          'code': 'failed',
        });
      } catch (_) {}
    }
  }

  Future<void> _print(HttpRequest request) async {
    if (_busy) {
      await request.drain<void>();
      await _json(request.response, HttpStatus.conflict, {
        'ok': false,
        'code': 'busy',
      });
      return;
    }
    if (!_printerReady()) {
      await request.drain<void>();
      await _json(request.response, HttpStatus.conflict, {
        'ok': false,
        'code': 'not_ready',
      });
      return;
    }
    final builder = BytesBuilder(copy: false);
    await for (final chunk in request) {
      builder.add(chunk);
      if (builder.length > 8 * 1024 * 1024) {
        await _json(request.response, HttpStatus.badRequest, {
          'ok': false,
          'code': 'too_large',
        });
        return;
      }
    }
    final bytes = builder.takeBytes();
    if (bytes.isEmpty) {
      await _json(request.response, HttpStatus.badRequest, {
        'ok': false,
        'code': 'empty',
      });
      return;
    }
    _busy = true;
    try {
      await _printPng(bytes);
      _log('Portal receipt sent.');
      await _json(request.response, HttpStatus.ok, {'ok': true});
    } on FormatException catch (error) {
      _log('Portal receipt was rejected: ${error.message}');
      await _json(request.response, HttpStatus.badRequest, {
        'ok': false,
        'code': 'bad_image',
      });
    } catch (error) {
      _log('Portal receipt failed: $error');
      await _json(request.response, HttpStatus.internalServerError, {
        'ok': false,
        'code': 'failed',
      });
    } finally {
      _busy = false;
    }
  }

  void _cors(HttpResponse response) {
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers', 'Content-Type');
    response.headers.set('Access-Control-Allow-Private-Network', 'true');
    response.headers.set('Cache-Control', 'no-store');
  }

  Future<void> _json(
    HttpResponse response,
    int status,
    Map<String, Object> body,
  ) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.json;
    response.write(jsonEncode(body));
    await response.close();
  }
}
