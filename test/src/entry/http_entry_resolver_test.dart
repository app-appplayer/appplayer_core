/// Resolver client and wire parsing (platform spec 19 §4.1).
library;

import 'dart:convert';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final endpoint = Uri.parse('https://entry.example.test/api/e');

  HttpEntryResolver resolverReturning(
    Object body, {
    void Function(Uri url, Map<String, String> headers)? spy,
  }) {
    return HttpEntryResolver(
      endpoint: endpoint,
      fetch: (url, {headers = const <String, String>{}}) async {
        spy?.call(url, headers);
        if (body is String) return body;
        return jsonEncode(body);
      },
    );
  }

  test('an https endpoint is required', () {
    // A resolver answered by anyone on the path decides what a viewer sees
    // and what authority they are handed.
    expect(
      () => HttpEntryResolver(
        endpoint: Uri.parse('http://entry.example.test/api/e'),
        fetch: (u, {headers = const <String, String>{}}) async => '{}',
      ),
      throwsArgumentError,
    );
  });

  test('the code becomes path segments and the locale is sent', () async {
    Uri? seen;
    Map<String, String>? sentHeaders;
    final resolver = resolverReturning(
      <String, dynamic>{'status': 'denied'},
      spy: (url, headers) {
        seen = url;
        sentHeaders = headers;
      },
    );
    await resolver.resolve('fleet/ABC123', locale: 'ko-KR');

    expect(seen.toString(), 'https://entry.example.test/api/e/fleet/ABC123');
    expect(sentHeaders!['accept-language'], 'ko-KR');
  });

  group('wire parsing', () {
    test('a full ok answer parses', () async {
      final resolver = resolverReturning(<String, dynamic>{
        'status': 'ok',
        'issuer': <String, dynamic>{'name': 'Fleet Co', 'verified': true},
        'target': <String, dynamic>{
          'kind': 'server',
          'ref': 'https://fleet.example.test/mcp',
          'route': '/contact',
          'params': <String, dynamic>{'plate': 'AB-1234'},
        },
        'identityPolicy': 'optional',
        'grant': <String, dynamic>{
          'token': 't',
          'expiresAt': '2026-07-29T12:00:00Z',
          'scope': <String>['relay.notify'],
        },
        'steward': <String, dynamic>{
          'kind': 'server',
          'ref': 'https://fleet.example.test/manage',
          'route': '/manage',
        },
        'notice': <String, dynamic>{
          'kind': 'custodyChanged',
          'message': 'Contact updated',
        },
        'validUntil': '2026-07-29T11:00:00Z',
      });

      final target = await resolver.resolve('c', locale: 'en');
      expect(target.isOk, isTrue);
      expect(target.issuer.name, 'Fleet Co');
      expect(target.identityPolicy, IdentityPolicy.optional);
      expect(target.target!.route, '/contact');
      expect(target.target!.params['plate'], 'AB-1234');
      expect(target.grant!.scope, <String>['relay.notify']);
      expect(target.steward, isNotNull);
      expect(target.notice!.kind, 'custodyChanged');
      expect(target.validUntil, isNotNull);
    });

    test('an unknown target kind leaves no target, so the answer is not ok',
        () async {
      final resolver = resolverReturning(<String, dynamic>{
        'status': 'ok',
        'issuer': <String, dynamic>{'name': 'Fleet Co'},
        'target': <String, dynamic>{'kind': 'hologram', 'ref': 'x'},
      });
      final target = await resolver.resolve('c', locale: 'en');
      expect(target.isOk, isFalse, reason: 'opening a guess is worse');
    });

    test('a missing identityPolicy demands identity', () async {
      final resolver = resolverReturning(<String, dynamic>{
        'status': 'ok',
        'issuer': <String, dynamic>{'name': 'Fleet Co'},
        'target': <String, dynamic>{'kind': 'server', 'ref': 'https://x.test'},
      });
      final target = await resolver.resolve('c', locale: 'en');
      expect(target.identityPolicy, IdentityPolicy.required);
    });

    test('a grant with no parsable expiry is dropped, not assumed eternal',
        () async {
      final resolver = resolverReturning(<String, dynamic>{
        'status': 'ok',
        'issuer': <String, dynamic>{'name': 'Fleet Co'},
        'target': <String, dynamic>{'kind': 'server', 'ref': 'https://x.test'},
        'grant': <String, dynamic>{'token': 't', 'expiresAt': 'never'},
      });
      final target = await resolver.resolve('c', locale: 'en');
      expect(target.grant, isNull);
    });

    test('an empty notice message carries no notice', () async {
      final resolver = resolverReturning(<String, dynamic>{
        'status': 'ok',
        'issuer': <String, dynamic>{'name': 'Fleet Co'},
        'target': <String, dynamic>{'kind': 'server', 'ref': 'https://x.test'},
        'notice': <String, dynamic>{'kind': 'advisory', 'message': ''},
      });
      expect((await resolver.resolve('c', locale: 'en')).notice, isNull);
    });
  });

  group('failure never becomes a guess', () {
    test('a non-JSON body is denied', () async {
      final resolver = resolverReturning('<html>nope</html>');
      final target = await resolver.resolve('c', locale: 'en');
      expect(target.status, EntryStatus.denied);
      expect(target.isOk, isFalse);
    });

    test('a JSON array is denied', () async {
      final resolver = resolverReturning(<dynamic>[1, 2, 3]);
      expect((await resolver.resolve('c', locale: 'en')).isOk, isFalse);
    });

    test('a transport failure is denied with a reason, not thrown', () async {
      final resolver = HttpEntryResolver(
        endpoint: endpoint,
        fetch: (u, {headers = const <String, String>{}}) async =>
            throw StateError('offline'),
      );
      final target = await resolver.resolve('c', locale: 'en');
      expect(target.status, EntryStatus.denied);
      expect(target.reason, 'resolver unreachable');
    });
  });
}
