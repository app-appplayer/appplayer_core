import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The vendored copy of `composition_host` must not drift from its recipe.
///
/// This package publishes to pub.dev and the recipe is `publish_to: none`, so
/// depending on it would make this package unpublishable — the copy is
/// deliberate. What is not deliberate is the copy quietly diverging: the recipe
/// is what another host (Vibe Studio, which drives the runtime without this
/// core) reads and builds against, so a fix applied to only one of them leaves
/// the reference describing behaviour the platform no longer has.
///
/// Skipped, loudly, when the recipe is not on disk — a consumer who fetched
/// this package from pub.dev has the copy but not the source tree.
void main() {
  test('vendored composition_host matches the recipe', () {
    final vendored = File('lib/src/core/composition_host_vendored.dart');
    final recipe = File(
        '../../brain_kernel/recipes/composition_host/lib/src/composition_host.dart');

    if (!recipe.existsSync()) {
      // ignore: avoid_print
      print('SKIP: recipe not on disk (published-package checkout) — '
          'drift cannot be checked here.');
      return;
    }

    // Everything below the vendoring header must be byte-identical. The header
    // is what makes the copy honest; the body is what must not move alone.
    const marker = "import 'dart:async';";
    final copy = vendored.readAsStringSync();
    final source = recipe.readAsStringSync();

    expect(copy.contains('VENDORED from'), isTrue,
        reason: 'the copy must say it is one, and where from');

    final copyBody = copy.substring(copy.indexOf(marker));
    final sourceBody = source.substring(source.indexOf(marker));

    expect(copyBody, sourceBody,
        reason: 'fix at the recipe and re-vendor — never edit only the copy');
  });
}
