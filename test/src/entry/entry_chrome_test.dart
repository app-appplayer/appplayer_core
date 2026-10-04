/// The trust chrome every entry is shown in (platform spec 19 §9.7).
library;

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const EntryIssuer _issuer = EntryIssuer(name: 'Fleet Co', verified: true);

Widget _app(Widget child) => MaterialApp(home: child);

void main() {
  group('where an external target may leave to', () {
    EntryTargetRef ext(String ref) =>
        EntryTargetRef(kind: EntryTargetKind.external, ref: ref);

    test('web · phone · mail · message leave', () {
      for (final ref in <String>[
        'https://example.com/a',
        'tel:+821000000000',
        'mailto:a@example.com',
        'sms:+821000000000',
      ]) {
        expect(entryLeaveDestination(ext(ref)), Uri.parse(ref), reason: ref);
      }
    });

    test('a scheme that could launch another app does not', () {
      for (final ref in <String>[
        'intent://x#Intent;end',
        'http://example.com',
        'javascript:alert(1)',
        'market://details?id=x',
      ]) {
        expect(entryLeaveDestination(ext(ref)), isNull, reason: ref);
      }
    });

    test('only external targets leave', () {
      expect(
        entryLeaveDestination(EntryTargetRef(
            kind: EntryTargetKind.server, ref: 'https://example.com/mcp')),
        isNull,
      );
    });
  });

  testWidgets('the frame names the issuer above whatever it holds',
      (tester) async {
    await tester.pumpWidget(_app(const EntryFrame(
      issuer: _issuer,
      notice: 'Custody changed',
      child: Text('target'),
    )));
    expect(find.text('Fleet Co'), findsOneWidget);
    expect(find.text('Verified issuer'), findsOneWidget);
    expect(find.text('Guest'), findsOneWidget);
    expect(find.text('Custody changed'), findsOneWidget);
    expect(find.text('target'), findsOneWidget);
    final issuerY = tester.getTopLeft(find.text('Fleet Co')).dy;
    expect(issuerY, lessThan(tester.getTopLeft(find.text('target')).dy));
  });

  testWidgets('an unnamed issuer is said to be unidentified', (tester) async {
    await tester.pumpWidget(_app(const EntryFrame(
      issuer: EntryIssuer(name: ''),
      child: SizedBox(),
    )));
    expect(find.text('Unidentified issuer'), findsOneWidget);
    expect(find.text('Not verified'), findsOneWidget);
  });

  testWidgets('leaving waits for a tap, then opens exactly the destination',
      (tester) async {
    final opened = <Uri>[];
    final destination = Uri.parse('tel:+821000000000');
    await tester.pumpWidget(_app(EntryLeaveScreen(
      issuer: _issuer,
      destination: destination,
      open: (uri) async {
        opened.add(uri);
        return true;
      },
    )));
    expect(find.text('Fleet Co'), findsOneWidget);
    expect(find.text('tel:+821000000000'), findsOneWidget);
    expect(opened, isEmpty, reason: 'nothing leaves before the tap');

    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(opened, <Uri>[destination]);
  });

  testWidgets('a destination nothing could open is said so', (tester) async {
    await tester.pumpWidget(_app(EntryLeaveScreen(
      issuer: _issuer,
      destination: Uri.parse('tel:+821000000000'),
      open: (uri) async => false,
    )));
    await tester.tap(find.text('Continue'));
    await tester.pump();
    expect(find.text('Nothing on this device could open it.'), findsOneWidget);
  });

  testWidgets("labels are the tier's words", (tester) async {
    await tester.pumpWidget(_app(const EntryFrame(
      issuer: _issuer,
      labels: EntryChromeLabels(verified: '확인된 발급자', guest: '손님'),
      child: SizedBox(),
    )));
    expect(find.text('확인된 발급자'), findsOneWidget);
    expect(find.text('손님'), findsOneWidget);
  });

  testWidgets('an opened entry can be left: a close control on the bar',
      (tester) async {
    // A desktop window has no system back; without this the viewer was
    // stuck on an entry once it opened.
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => const EntryFrame(
              issuer: EntryIssuer(name: 'Seoul Parking', verified: true),
              child: Text('page'),
            ),
          )),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('page'), findsOneWidget);

    await tester.tap(find.byKey(const Key('entry-close')));
    await tester.pumpAndSettle();
    expect(find.text('page'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a first screen has nothing to close', (tester) async {
    await tester.pumpWidget(_app(const EntryFrame(
      issuer: EntryIssuer(name: 'Seoul Parking', verified: true),
      child: Text('page'),
    )));
    expect(find.byKey(const Key('entry-close')), findsNothing);
  });
}
