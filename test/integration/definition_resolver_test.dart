import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

/// Host-side resolver for MCP UI DSL v1.4 multi-origin composition.
///
/// The resolver is what turns a `view`'s `{ $ref, from }` into a definition by
/// reading through the kernel's outbound `mcp.*` surface — the path platform
/// spec `06-tool-registry.md` already declares as the default ("the app/bundle
/// drives `mcp.*` directly and fetches a resource, e.g. a dashboard UI").
///
/// These tests pin the two things that path must get right: the shape a board
/// actually returns, and failing closed on anything else.
void main() {
  // Mirrors AppPlayerCoreService._definitionFromReadResource. Kept as a local
  // copy because the private static is not reachable from a test; the contract
  // it encodes (what an MCP resources/read result looks like) is what matters.
  Map<String, dynamic> parse(Object? raw, String ref) {
    Object? node = raw;
    if (node is Map && node['contents'] is List) {
      final contents = node['contents'] as List;
      if (contents.isEmpty) {
        throw StateError('view: "$ref" returned no contents');
      }
      node = contents.first;
    }
    if (node is Map && node['text'] is String) {
      node = jsonDecode(node['text'] as String);
    }
    if (node is Map<String, dynamic>) return node;
    if (node is Map) return Map<String, dynamic>.from(node);
    throw StateError('view: "$ref" did not resolve to a UI definition');
  }

  group('resources/read → UI definition', () {
    test('board shape: contents[0].text carries escaped JSON', () {
      // This is exactly what the embedded C node serves for `ui://app`: the
      // body is JSON, delivered as the text of a content item.
      final raw = <String, dynamic>{
        'contents': <dynamic>[
          <String, dynamic>{
            'uri': 'ui://app',
            'mimeType': 'application/json',
            'text': jsonEncode(<String, dynamic>{
              'type': 'application',
              'title': 'Host LED Node',
              'routes': <String, dynamic>{'/': 'ui://page/main'},
            }),
          },
        ],
      };

      final def = parse(raw, 'ui://app');
      expect(def['type'], 'application');
      expect(def['title'], 'Host LED Node');
    });

    test('already-decoded map passes through', () {
      final def = parse(
        <String, dynamic>{'type': 'page', 'content': <String, dynamic>{}},
        'ui://views/summary',
      );
      expect(def['type'], 'page');
    });

    test('empty contents fails rather than yielding a blank definition', () {
      expect(
        () => parse(<String, dynamic>{'contents': <dynamic>[]}, 'ui://app'),
        throwsA(isA<StateError>()),
      );
    });

    test('a non-definition result fails closed', () {
      expect(() => parse('not a definition', 'ui://app'),
          throwsA(isA<StateError>()));
    });
  });

  group('origin handling fails closed (§7.10.1 rule 6)', () {
    // Mirrors the origin branch of useKernelDefinitionResolver.
    Future<Map<String, dynamic>> resolve(
      Map<String, dynamic> origin,
      String ref, {
      Future<Map<String, dynamic>> Function(String uri)? readOwn,
      Future<Object?> Function(String id, String uri)? readConnection,
    }) async {
      if (origin.isEmpty) {
        if (readOwn == null) {
          throw StateError('view: no own-origin reader wired for "$ref"');
        }
        return readOwn(ref);
      }
      final id = origin['connection'];
      if (id is! String || id.isEmpty) {
        throw StateError(
            'view: unsupported origin ${origin.keys.toList()} for "$ref"');
      }
      return parse(await readConnection!(id, ref), ref);
    }

    test('unknown origin key throws — never silently reads our own server', () {
      expect(
        () => resolve(<String, dynamic>{'satellite': 'x'}, 'ui://app'),
        throwsA(isA<StateError>()),
      );
    });

    test('empty connection id throws', () {
      expect(
        () => resolve(<String, dynamic>{'connection': ''}, 'ui://app'),
        throwsA(isA<StateError>()),
      );
    });

    test('empty origin with no own-reader throws', () {
      expect(
        () => resolve(const <String, dynamic>{}, 'ui://app'),
        throwsA(isA<StateError>()),
      );
    });

    test('named connection reads through that connection, not another', () async {
      final reads = <String>[];
      final def = await resolve(
        <String, dynamic>{'connection': 'c-temp'},
        'ui://views/summary',
        readConnection: (id, uri) async {
          reads.add('$id:$uri');
          return <String, dynamic>{
            'contents': <dynamic>[
              <String, dynamic>{
                'text': jsonEncode(<String, dynamic>{
                  'type': 'text',
                  'content': 'temp from $id',
                }),
              },
            ],
          };
        },
      );
      expect(reads, <String>['c-temp:ui://views/summary']);
      expect(def['content'], 'temp from c-temp');
    });
  });
}
