// The debug input tools have to take the paths a user's finger takes.
//
// `typeText` used to assign `controller.value` under a comment claiming that
// fired `onChanged`. It does not: Flutter reaches `onChanged` from
// `updateEditingValue` → `_formatAndSetValue`, and a controller assignment
// goes down `_didChangeTextEditingValue`, which has no such call. The text
// appeared in the field either way, so the tool looked correct — while the
// DSL runtime, which writes bound state from inside `onChanged`, saw nothing.
// Every input widget measured with it read as "the letters go in and the
// binding stays empty", and a consumer nearly filed that as a runtime defect.
//
// So these tests assert the *path*, not the field contents: what did the
// widget's own callbacks see.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_core/internals.dart';

Future<DebugSurface> _pumpField(
  WidgetTester tester, {
  required TextEditingController controller,
  required FocusNode focusNode,
  required void Function(String) onChanged,
  void Function(String)? onSubmitted,
  bool readOnly = false,
}) async {
  final surface = DebugSurface();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: RepaintBoundary(
        key: surface.captureKey,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          readOnly: readOnly,
          onChanged: onChanged,
          onSubmitted: onSubmitted,
        ),
      ),
    ),
  ));
  focusNode.requestFocus();
  await tester.pump();
  return surface;
}

void main() {
  group('typeText takes the keystroke path', () {
    testWidgets('the field fires onChanged, as a real keystroke would',
        (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      final changes = <String>[];

      final surface = await _pumpField(
        tester,
        controller: controller,
        focusNode: focusNode,
        onChanged: changes.add,
      );

      final result = await surface.typeText('alpha');
      await tester.pump();

      expect(result['ok'], isTrue);
      expect(controller.text, 'alpha');
      expect(changes, ['alpha'],
          reason: 'the DSL runtime writes bound state from inside onChanged; '
              'without this call the binding stays empty while the field '
              'shows the text');
      expect(result['asKeystroke'], isTrue);
    });

    testWidgets('a readOnly field is a no-op rather than a forced write',
        (tester) async {
      // The old assignment wrote into readOnly fields too — the tool
      // pretended to a capability the app does not have.
      final controller = TextEditingController(text: 'locked');
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      final changes = <String>[];

      final surface = await _pumpField(
        tester,
        controller: controller,
        focusNode: focusNode,
        onChanged: changes.add,
        readOnly: true,
      );

      await surface.typeText('bravo');
      await tester.pump();

      expect(controller.text, 'locked');
      expect(changes, isEmpty);
    });

    testWidgets('submit reports itself and carries the typed value',
        (tester) async {
      final controller = TextEditingController();
      final focusNode = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(focusNode.dispose);
      final changes = <String>[];
      final submits = <String>[];

      final surface = await _pumpField(
        tester,
        controller: controller,
        focusNode: focusNode,
        onChanged: changes.add,
        onSubmitted: submits.add,
      );

      final result = await surface.typeText('charlie', submit: true);
      await tester.pump();

      expect(submits, ['charlie']);
      expect(changes, ['charlie'],
          reason: 'submit must not replace the keystroke — a document that '
              'binds onChange and onSubmit needs both to have happened');
      expect(result['submitted'], isTrue);
    });
  });

  // The tap primitives are deliberately NOT tested here. Measured: a
  // synthetic `PointerDownEvent` dispatched through `GestureBinding` never
  // reaches the widget under `flutter test` — a `Listener` on the target
  // counts zero downs — because the single-view `hitTest` this recipe relies
  // on resolves against the test view rather than the rendered surface. A test
  // written here would be measuring the harness. `ui.tap`'s `longPress` /
  // `button` extension is verified on a built app through the debug MCP, which
  // is the surface it exists to drive.
}
