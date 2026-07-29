/// Reading an entry code out of a link (platform spec 19 §3).
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

EntryLink parse(String url) => EntryLink.parse(
      Uri.parse(url),
      claimedHosts: const <String>{'entry.example.test'},
      pathPrefix: '/e',
    );

void main() {
  group('§3.1 form', () {
    test('an https link on a claimed host in the entry path is an entry', () {
      final link = parse('https://entry.example.test/e/ABC123');
      expect(link.isEntry, isTrue);
      expect(link.code, 'ABC123');
    });

    test('a custom scheme is not an entry', () {
      // It fails silently on a device without the app, which is the majority
      // case for a stranger scanning a printed thing.
      final link = parse('appplayer://e/ABC123');
      expect(link.rejection, EntryLinkRejection.notHttps);
    });

    test('plain http is not an entry', () {
      expect(parse('http://entry.example.test/e/ABC123').rejection,
          EntryLinkRejection.notHttps);
    });
  });

  group('claimed hosts', () {
    test('a host this build does not claim is rejected', () {
      expect(parse('https://other.test/e/ABC123').rejection,
          EntryLinkRejection.unclaimedHost);
    });

    test('a lookalike suffix is not the claimed host', () {
      // Suffix matching would hand `evil-entry.example.test` our registry.
      expect(parse('https://evil-entry.example.test/e/ABC').rejection,
          EntryLinkRejection.unclaimedHost);
      expect(parse('https://entry.example.test.evil.test/e/ABC').rejection,
          EntryLinkRejection.unclaimedHost);
    });

    test('host matching ignores case', () {
      expect(parse('https://ENTRY.EXAMPLE.TEST/e/ABC').isEntry, isTrue);
    });
  });

  group('§3.4 path space', () {
    test('another path on the same host is not an entry', () {
      expect(parse('https://entry.example.test/about').rejection,
          EntryLinkRejection.notEntryPath);
    });

    test('the prefix alone carries no code', () {
      expect(parse('https://entry.example.test/e').rejection,
          EntryLinkRejection.noCode);
      expect(parse('https://entry.example.test/e/').rejection,
          EntryLinkRejection.noCode);
    });

    test('a partitioned code space stays opaque to this side', () {
      // An issuer may shape its code space however it likes; the client must
      // not need to know the shape.
      final link = parse('https://entry.example.test/e/fleet/2026/ABC123');
      expect(link.code, 'fleet/2026/ABC123');
    });
  });

  group('§3.3 opacity', () {
    test('a query string is not part of the code', () {
      // The destination never rides in the link — that is what lets a medium
      // be rebound without reprinting it.
      final link = parse('https://entry.example.test/e/ABC?target=evil');
      expect(link.code, 'ABC');
    });
  });

  test('rejection is reported, not swallowed', () {
    // The host falls through to whatever it normally does with a URL; a
    // silently dropped link is a dead tap with nothing to debug.
    for (final url in <String>[
      'https://other.test/e/A',
      'https://entry.example.test/about',
      'appplayer://e/A',
    ]) {
      expect(parse(url).rejection, isNotNull);
      expect(parse(url).isEntry, isFalse);
    }
  });
}
