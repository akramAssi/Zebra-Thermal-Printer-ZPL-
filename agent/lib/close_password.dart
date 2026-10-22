import 'dart:convert';
import 'dart:io';

import 'agent_log.dart';

/// Used when the portal has no password yet, or the app cannot reach it.
const String kDefaultClosePassword = 'shini';

/// Portal the printer app asks for `printer_agent.close_password`.
const String kPortalApiBaseUrl = 'https://online.shini.ps/roastery/api';

/// Same value as `printer_agent.access_key` in App configuration.
const String kPortalAccessKey = 'PM8xrSBk_wWLBAecXOtN3lEdhxmd9Hk-';

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

/// First real line is the API base, second is the access key.
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

/// The portal `message` field, without the password.
String portalReplyMessage(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is Map && decoded['message'] is String) {
      final message = (decoded['message'] as String).trim();
      if (message.isNotEmpty) return message;
    }
  } catch (_) {}
  return 'no message';
}

bool portalBodyHasPassword(String body) {
  try {
    final decoded = jsonDecode(body);
    if (decoded is! Map) return false;
    final data = decoded['data'];
    if (data is! Map) return false;
    final password = data['password'];
    return password is String && password.trim().isNotEmpty;
  } catch (_) {
    return false;
  }
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
  agentLog('Asking $uri for the close password.');
  try {
    final request = await client.getUrl(uri);
    request.headers.set('x-printer-agent-key', link.accessKey!);
    final response = await request.close().timeout(const Duration(seconds: 8));
    final text = await utf8.decoder.bind(response).join();
    agentLog(
      'Portal answered HTTP ${response.statusCode}: ${portalReplyMessage(text)}',
    );
    if (response.statusCode != 200) {
      agentLog('Close password stayed on the built-in password.');
      return fallback;
    }
    if (!portalBodyHasPassword(text)) {
      agentLog(
        'Portal response had no close password. Close password stayed on the built-in password.',
      );
      return fallback;
    }
    agentLog('Close password was loaded from the portal.');
    return closePasswordFromPortalBody(text, fallback: fallback);
  } catch (error) {
    agentLog(
      'Could not reach the portal ($error). Close password stayed on the built-in password.',
    );
    return fallback;
  } finally {
    client.close(force: true);
  }
}

/// Asks the built-in portal address for the quit password.
Future<String> loadClosePassword({
  String fallback = kDefaultClosePassword,
}) async {
  final link = const PortalLink(
    apiBaseUrl: kPortalApiBaseUrl,
    accessKey: kPortalAccessKey,
  );
  if (!link.canFetch) {
    agentLog(
      'Portal address or access key is empty. Using the built-in close password.',
    );
    return fallback;
  }
  return fetchClosePassword(link, fallback: fallback);
}
