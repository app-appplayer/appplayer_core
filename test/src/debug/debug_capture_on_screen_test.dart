// The snapshot tools answer for what is on screen, and only that.
//
// `ui.text` walks the render tree, and a render tree holds more than the
// screen shows: a tab page kept alive off-stage stays attached with its last
// size and, after a state update, no defined geometry. One NaN rect failed
// the JSON encode and took every visible text with it; before the update
// the same page leaked its text at off-screen coordinates. Measured by konpi
// on two tab apps (pos-kiosk-kds, taxi-dashboard) after Order -> Kitchen and
// Driver -> Trip.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:appplayer_core/internals.dart';

class _KeptPage extends StatefulWidget {
  const _KeptPage(this.label, this.tick);
  final String label;
  final int tick;

  @override
  State<_KeptPage> createState() => _KeptPageState();
}

class _KeptPageState extends State<_KeptPage>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      children: [
        const Spacer(),
        Text('${widget.label} ${widget.tick}'),
        const Spacer(),
      ],
    );
  }
}

class _TabsApp extends StatefulWidget {
  const _TabsApp(this.surface, {super.key});
  final DebugSurface surface;

  @override
  State<_TabsApp> createState() => _TabsAppState();
}

class _TabsAppState extends State<_TabsApp> {
  int tick = 0;
  void bump() => setState(() => tick++);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: DefaultTabController(
        length: 2,
        child: Scaffold(
          appBar: AppBar(
            bottom:
                const TabBar(tabs: [Tab(text: 'Order'), Tab(text: 'Kitchen')]),
          ),
          body: RepaintBoundary(
            key: widget.surface.captureKey,
            child: TabBarView(
              children: [
                _KeptPage('order-page', tick),
                _KeptPage('kitchen-page', tick),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// A synthetic non-finite transform cannot be pinned in a widget test: the
// semantics pass asserts `offset.isFinite` before the tool runs. The kept-alive
// tab page above is the real producer of that geometry, and the encode
// assertion there is the regression.

void main() {
  testWidgets(
      'a kept-alive tab page behind the front one is not in the answer, and the answer encodes',
      (tester) async {
    final surface = DebugSurface();
    final key = GlobalKey<_TabsAppState>();
    await tester.pumpWidget(_TabsApp(surface, key: key));
    await tester.pumpAndSettle();

    expect(surface.textSnapshot().map((e) => e['text']), ['order-page 0']);

    await tester.tap(find.text('Kitchen'));
    await tester.pumpAndSettle();
    key.currentState!.bump();
    await tester.pump();
    await tester.pump();

    final snapshot = surface.textSnapshot();
    expect(() => jsonEncode(snapshot), returnsNormally,
        reason: 'one NaN rect failed the encode and lost every text');
    expect(snapshot.map((e) => e['text']), ['kitchen-page 1'],
        reason: 'the page behind is attached and sized, and not on screen');
    final layout = surface.layoutSnapshot();
    expect(() => jsonEncode(layout), returnsNormally);
  });

  testWidgets('text laid out beyond the capture surface is not on screen',
      (tester) async {
    final surface = DebugSurface();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepaintBoundary(
          key: surface.captureKey,
          child: Stack(clipBehavior: Clip.none, children: const [
            Text('here'),
            Positioned(left: 5000, top: 0, child: Text('elsewhere')),
          ]),
        ),
      ),
    ));
    await tester.pump();
    expect(surface.textSnapshot().map((e) => e['text']), ['here']);
    expect(surface.resolveElementRect('elsewhere'), isNull);
  });
}
