// The tool router is installed before `initialize`, not only at `buildUI`.
//
// A definition-level `onInit` fires inside `initialize` (MCP UI DSL §1.5.2:
// `onInit` precedes the first render), and the runtime's executor used to be
// registered from `buildUI`. An application whose `onInit` calls a tool
// therefore reached nothing — no error surfaced to the author, and the server
// simply never saw the call.
//
// `routerFor` is the shared routing both moments use; two copies would drift,
// and a drift here means the hook and the rest of the app disagree about
// where a tool goes.

import 'package:appplayer_core/src/runtime/tool_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ToolDispatcher.routerFor', () {
    test('routes an in-process tool with no client', () async {
      final seen = <String, Map<String, dynamic>>{};
      final dispatcher = ToolDispatcher()
        ..registerInProcessTool('menu.list', (params) async {
          seen['menu.list'] = params;
          return <String, dynamic>{'items': <String>[]};
        });

      final router = dispatcher.routerFor(null);
      final result =
          await router('menu.list', <String, dynamic>{'store': 'a'});

      expect(result, <String, dynamic>{'items': <String>[]});
      expect(seen['menu.list'], <String, dynamic>{'store': 'a'});
    });

    test('an unknown tool with no client reports rather than throwing',
        () async {
      final unrouted = <String>[];
      final dispatcher = ToolDispatcher();
      final router = dispatcher.routerFor(null, onNoClient: unrouted.add);

      expect(await router('menu.list', <String, dynamic>{}), isNull);
      expect(unrouted, <String>['menu.list'],
          reason: 'a call that goes nowhere has to say so');
    });

    test('the no-client callback is not fired for a tool that did route',
        () async {
      final unrouted = <String>[];
      final dispatcher = ToolDispatcher()
        ..registerInProcessTool('ok', (params) async => 1);
      final router = dispatcher.routerFor(null, onNoClient: unrouted.add);

      await router('ok', <String, dynamic>{});
      expect(unrouted, isEmpty);
    });
  });
}
