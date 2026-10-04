/// Two apps open at once, drawn side by side the way a host lays out a
/// dashboard or a split view: what one app does stays in that app. A button in
/// A moves A, a dialog from A is A's, and A's palette does not colour B.
///
/// Both apps are opened through the core as real sessions (one runtime per
/// app handle), not built as bare runtimes — the seam a host actually uses.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

const _a = 'com.example.side_a';
const _b = 'com.example.side_b';
const _tabsA = 'com.example.tabs_a';
const _tabsB = 'com.example.tabs_b';

String _fixture(String id) =>
    '${Directory.current.path}/test/fixtures/${id.split('.').last}.mbd';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPlayerCoreService core;
  late AppSession a;
  late AppSession b;

  /// Pages load over real async work; fake pumps alone never see them.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 60 && !done(); i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> openBoth(WidgetTester tester,
      {String left = _a, String right = _b}) async {
    await tester.runAsync(() async {
      final tmp = await Directory.systemTemp.createTemp('appplayer-side-');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      core = AppPlayerCoreService();
      await core.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: tmp.path,
      );
      await core.installBundleFromDirectory(_fixture(_a));
      await core.installBundleFromDirectory(_fixture(_b));
      await core.installBundleFromDirectory(_fixture(_tabsA));
      await core.installBundleFromDirectory(_fixture(_tabsB));
      a = await core.openAppFromBundle(BundleInstalledRef(left));
      b = await core.openAppFromBundle(BundleInstalledRef(right));
    });
    addTearDown(() async {
      await a.close();
      await b.close();
      await core.dispose();
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('A'),
                child: Builder(builder: (c) => a.buildWidget(context: c)),
              ),
            ),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('B'),
                child: Builder(builder: (c) => b.buildWidget(context: c)),
              ),
            ),
          ],
        ),
      ),
    ));
    await settle(
        tester,
        () =>
            find.textContaining('B ').evaluate().isNotEmpty &&
            find.textContaining('A ').evaluate().isNotEmpty);
  }

  testWidgets('a button in A moves A, not B', (tester) async {
    await openBoth(tester);
    expect(find.text('A HOME'), findsOneWidget);
    expect(find.text('B HOME'), findsOneWidget);

    await tester.tap(find.text('A NEXT'));
    await settle(tester, () => find.text('A NEXT PAGE').evaluate().isNotEmpty);

    expect(find.text('A NEXT PAGE'), findsOneWidget);
    expect(find.text('B HOME'), findsOneWidget,
        reason: 'the other app stays where it was');
    expect(find.text('B NEXT PAGE'), findsNothing);
  });

  testWidgets('a button in B moves B, not A', (tester) async {
    await openBoth(tester);
    await tester.tap(find.text('B NEXT'));
    await settle(tester, () => find.text('B NEXT PAGE').evaluate().isNotEmpty);
    expect(find.text('B NEXT PAGE'), findsOneWidget);
    expect(find.text('A HOME'), findsOneWidget);
  });

  testWidgets('a dialog from A opens once, as A\'s', (tester) async {
    await openBoth(tester);
    await tester.tap(find.text('A ASK'));
    await settle(tester, () => find.text('A DIALOG').evaluate().isNotEmpty);
    Finder inside(String side, Finder f) =>
        find.descendant(of: find.byKey(ValueKey(side)), matching: f);
    expect(inside('A', find.text('A DIALOG')), findsOneWidget);
    expect(inside('B', find.text('A DIALOG')), findsNothing);

    await tester.tap(find.text('B ASK'));
    await settle(tester, () => find.text('B DIALOG').evaluate().isNotEmpty);
    expect(inside('B', find.text('B DIALOG')), findsOneWidget,
        reason: 'a dialog open in A is no reason to refuse one in B');
  });

  testWidgets('A\'s palette does not colour B', (tester) async {
    await openBoth(tester);
    Color? primaryOf(String label) {
      final button = find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      );
      final context = tester.element(button.first);
      return Theme.of(context).colorScheme.primary;
    }

    final aPrimary = primaryOf('A NEXT');
    final bPrimary = primaryOf('B NEXT');
    expect(aPrimary, const Color(0xFFFF0000));
    expect(bPrimary, isNot(const Color(0xFFFF0000)),
        reason: 'B declared no theme and keeps its own defaults');
  });

  testWidgets('A closed and opened again keeps its palette; B still its own',
      (tester) async {
    await openBoth(tester);
    await tester.runAsync(() async {
      await a.close();
      a = await core.openAppFromBundle(const BundleInstalledRef(_a));
    });
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('A'),
                child: Builder(builder: (c) => a.buildWidget(context: c)),
              ),
            ),
            Expanded(
              child: KeyedSubtree(
                key: const ValueKey('B'),
                child: Builder(builder: (c) => b.buildWidget(context: c)),
              ),
            ),
          ],
        ),
      ),
    ));
    await settle(tester, () => find.text('A HOME').evaluate().isNotEmpty);
    Color primaryOf(String label) => Theme.of(tester.element(find
            .ancestor(
              of: find.text(label),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
            )
            .first))
        .colorScheme
        .primary;
    expect(primaryOf('A NEXT'), const Color(0xFFFF0000));
    expect(primaryOf('B NEXT'), isNot(const Color(0xFFFF0000)));
  });

  testWidgets('two tab-shell apps each go to their own tab', (tester) async {
    await openBoth(tester, left: _tabsA, right: _tabsB);
    expect(find.text('A TAB HOME'), findsOneWidget);
    expect(find.text('B TAB HOME'), findsOneWidget);

    await tester.tap(find.text('A GO'));
    await settle(tester, () => find.text('A TAB NEXT').evaluate().isNotEmpty);

    expect(find.text('A TAB NEXT'), findsOneWidget);
    expect(find.text('B TAB HOME'), findsOneWidget,
        reason: 'the shell opened last must not take A\'s navigation');
  });
}
