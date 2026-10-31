import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Used when the portal has no password yet, or the app cannot reach it.
const String kDefaultClosePassword = 'shini';

class PortalLink {
  const PortalLink({this.apiBaseUrl, this.accessKey});

  final String? apiBaseUrl;
  final String? accessKey;

  bool get canFetch {
    final url = apiBaseUrl;
    final key = accessKey;
    return url != null && url.isNotEmpty && key != null && key.isNotEmpty;
  }
}

/// `portal.txt`: first real line is the API base, second is the access key.
/// Blank lines and lines starting with `#` are skipped.
PortalLink portalLinkFrom(String? fileText) {
  final lines = (fileText ?? '')
      .split(RegExp(r'\r?\n'))
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();
  return PortalLink(
    apiBaseUrl: lines.isEmpty ? null : lines[0],
    accessKey: lines.length < 2 ? null : lines[1],
  );
}

String closePasswordFromPortalBody(
  String body, {
  String fallback = kDefaultClosePassword,
}) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return fallback;
    final data = decoded['data'];
    if (data is! Map) return fallback;
    final password = data['password'];
    if (password is! String) return fallback;
    final trimmed = password.trim();
    if (trimmed.isEmpty) return fallback;
    return trimmed;
  } catch (_) {
    return fallback;
  }
}

Future<String> fetchClosePassword(
  PortalLink link, {
  required String fallback,
}) async {
  if (!link.canFetch) return fallback;
  final root = link.apiBaseUrl!.replaceFirst(RegExp(r'/+$'), '');
  final uri = Uri.parse('$root/printer-agent/close-password');
  final client = HttpClient();
  client.connectionTimeout = const Duration(seconds: 8);
  try {
    final request = await client.getUrl(uri);
    request.headers.set('x-printer-agent-key', link.accessKey!);
    final response = await request.close().timeout(const Duration(seconds: 8));
    final text = await utf8.decoder.bind(response).join();
    if (response.statusCode != 200) return fallback;
    return closePasswordFromPortalBody(text, fallback: fallback);
  } catch (_) {
    return fallback;
  } finally {
    client.close(force: true);
  }
}

/// Windows keeps an editable `portal.txt` beside the exe.
/// iOS and Android ship that same file inside the installed app.
Future<String?> portalTextBesideExecutable() async {
  if (!Platform.isWindows) return null;
  final file = File.fromUri(
    File(Platform.resolvedExecutable).parent.uri.resolve('portal.txt'),
  );
  if (!await file.exists()) return null;
  return file.readAsString();
}

Future<String?> bundledPortalText() async {
  try {
    return await rootBundle.loadString('portal.txt');
  } catch (_) {
    return null;
  }
}

/// Asks the portal for the quit password.
///
/// A `portal.txt` beside the Windows exe wins. On iOS and Android, and when
/// that file is missing, the copy bundled in the installed app is used.
Future<String> loadClosePassword({
  String fallback = kDefaultClosePassword,
}) async {
  final beside = await portalTextBesideExecutable();
  if (beside != null) {
    return fetchClosePassword(portalLinkFrom(beside), fallback: fallback);
  }
  final bundled = await bundledPortalText();
  if (bundled == null) return fallback;
  return fetchClosePassword(portalLinkFrom(bundled), fallback: fallback);
}
