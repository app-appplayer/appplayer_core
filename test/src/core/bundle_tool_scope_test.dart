/// A bundle's own tools are isolated under its id, and the bundle reaches them
/// by the names it declared (platform spec 04 name isolation · 06 stable names).
///
/// Two bundles here declare the same tool, `board.summary`. Registered bare,
/// the second opened would answer for both. Registered only under the full
/// name, a bundle calling its own tool by the declared name would reach
/// nothing — and it cannot write the full name itself, because the id it runs
/// under can be set at install.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const _a = 'com.example.tool_scope_a';
const _b = 'com.example.tool_scope_b';

String _fixture(String id) =>
    '${Directory.current.path}/test/fixtures/${id.split('.').last}.mbd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPlayerCoreService core;

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-scope-test-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async => core.dispose());
    await core.installBundleFromDirectory(_fixture(_a));
    await core.installBundleFromDirectory(_fixture(_b));
  });

  test('each bundle\'s tool is registered under its own id, never bare',
      () async {
    final a = await core.openAppFromBundle(const BundleInstalledRef(_a));
    final b = await core.openAppFromBundle(const BundleInstalledRef(_b));
    addTearDown(a.close);
    addTearDown(b.close);

    final names = core.inProcessToolNames;
    expect(names, containsAll(['$_a.board.summary', '$_b.board.summary']));
    expect(names, isNot(contains('board.summary')));
  });

  test('inside a bundle the declared name reaches that bundle\'s own tool',
      () async {
    final a = await core.openAppFromBundle(const BundleInstalledRef(_a));
    final b = await core.openAppFromBundle(const BundleInstalledRef(_b));
    addTearDown(a.close);
    addTearDown(b.close);

    final tools = core.toolDispatcherForInternals;
    final fromA = await tools.routerFor(null, scope: _a)(
        'board.summary', <String, dynamic>{});
    final fromB = await tools.routerFor(null, scope: _b)(
        'board.summary', <String, dynamic>{});
    expect(fromA, {'from': 'a'});
    expect(fromB, {'from': 'b'});

    // The full name works from anywhere, including another bundle.
    expect(
      await tools.routerFor(null, scope: _b)(
          '$_a.board.summary', <String, dynamic>{}),
      {'from': 'a'},
    );
  });

  test('outside any bundle the declared name alone reaches nothing', () async {
    final a = await core.openAppFromBundle(const BundleInstalledRef(_a));
    addTearDown(a.close);

    await expectLater(
      core.toolDispatcherForInternals.routerFor(null)(
          'board.summary', <String, dynamic>{}),
      throwsA(isA<ToolExecutionException>()),
    );
  });

  // The route a person takes: a button in the bundle's own page calls the
  // declared name. Both bundles are open, so a call that left the bundle's
  // namespace would either miss or be answered by the other one.
  for (final (id, expected) in [(_a, 'a'), (_b, 'b')]) {
    testWidgets('a button in $id reaches its own tool by the declared name',
        (tester) async {
      final other = id == _a ? _b : _a;
      late AppSession session;
      await tester.runAsync(() async {
        final o = await core.openAppFromBundle(BundleInstalledRef(other));
        addTearDown(o.close);
        session = await core.openAppFromBundle(BundleInstalledRef(id));
      });
      addTearDown(session.close);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => session.buildWidget(context: context),
          ),
        ),
      ));
      for (var i = 0;
          i < 50 && find.text('answered none').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump();
      }
      expect(find.text('answered none'), findsOneWidget,
          reason:
              'on screen: ${find.byType(Text).evaluate().map((e) => (e.widget as Text).data).toList()}');

      await tester.tap(find.text('Ask'));
      // The tool runs in a worker isolate: real time, not fake pumps.
      for (var i = 0;
          i < 50 && find.text('answered $expected').evaluate().isEmpty;
          i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)));
        await tester.pump();
      }
      expect(find.text('answered $expected'), findsOneWidget);
    });
  }

  test('closing a bundle takes its full-name registration with it', () async {
    final a = await core.openAppFromBundle(const BundleInstalledRef(_a));
    expect(core.inProcessToolNames, contains('$_a.board.summary'));
    await a.close();
    expect(core.inProcessToolNames, isNot(contains('$_a.board.summary')));
  });
}
