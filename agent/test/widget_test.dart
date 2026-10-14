import 'package:flutter_test/flutter_test.dart';
import 'package:zebra_printer_agent/close_password.dart';

void main() {
  test('comments and blank lines are ignored', () {
    const file = '''
# portal API
https://online.shini.ps/roastery/api

# access key
warehouse-key
''';
    final link = portalLinkFrom(file);
    expect(link.apiBaseUrl, 'https://online.shini.ps/roastery/api');
    expect(link.accessKey, 'warehouse-key');
    expect(link.canFetch, isTrue);
  });

  test('missing access key does not call the portal', () {
    final link = portalLinkFrom('https://online.shini.ps/roastery/api\n');
    expect(link.canFetch, isFalse);
    expect(portalLinkFrom(null).canFetch, isFalse);
    expect(portalLinkFrom('# only a comment\n').canFetch, isFalse);
  });

  test('portal body replaces the password', () {
    const body = '{"success":true,"data":{"password":" warehouse "}}';
    expect(closePasswordFromPortalBody(body), 'warehouse');
  });

  test('bad portal body keeps the current password', () {
    expect(closePasswordFromPortalBody('nope', fallback: 'kept'), 'kept');
    expect(
      closePasswordFromPortalBody(
        '{"success":true,"data":{"password":"  "}}',
        fallback: 'kept',
      ),
      'kept',
    );
  });
}
