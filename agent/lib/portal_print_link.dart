/// `zebraprinter://print?token=...&api=https://host/api`
class PortalPrintLink {
  const PortalPrintLink({required this.token, required this.apiBase});

  final String token;
  final String apiBase;

  Uri get fileUri {
    final root = apiBase.replaceFirst(RegExp(r'/+$'), '');
    return Uri.parse('$root/printer-agent/print-jobs/$token');
  }
}

PortalPrintLink? portalPrintLinkFrom(Uri uri) {
  if (uri.scheme != 'zebraprinter') return null;
  final token = uri.queryParameters['token']?.trim() ?? '';
  var api = uri.queryParameters['api']?.trim() ?? '';
  if (token.isEmpty || api.isEmpty) return null;
  if (!api.startsWith('https://') && !api.startsWith('http://')) return null;
  api = api.replaceFirst(RegExp(r'/+$'), '');
  return PortalPrintLink(token: token, apiBase: api);
}
