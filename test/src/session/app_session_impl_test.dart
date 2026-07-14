import 'package:appplayer_core/internals.dart';
import 'package:appplayer_core/src/logging/logger.dart';
import 'package:appplayer_core/src/session/app_handle.dart';
import 'package:appplayer_core/src/session/app_session_impl.dart';
import 'package:flutter/material.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart'
    show MCPUIRuntime;
import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../../helpers/mocks.dart';

AppSessionImpl _session({
  AppHandle? handle,
  mb.McpBundle? bundle,
  List<String> jsToolNames = const <String>[],
  Future<void> Function()? onClose,
}) {
  return AppSessionImpl(
    handle: handle ?? const AppHandle.server('s1'),
    runtime: MockMCPUIRuntime(),
    conn: ConnectionManager(),
    runtimeManager: RuntimeManager(),
    toolDispatcher: ToolDispatcher(),
    resourceSubscriber: ResourceSubscriber(),
    logger: NoopLogger(),
    bundle: bundle,
    jsToolNames: jsToolNames,
    onClose: onClose,
  );
}

void main() {
  group('AppSessionImpl — host brightness re-injection', () {
    testWidgets(
        'buildWidget re-injects the CURRENT host brightness on every entry — '
        'the runtime ThemeManager is a process-wide singleton and another '
        'widget\'s dispose clears the pin, so one-shot setup left the next '
        'app entry rendering light content in dark mode', (tester) async {
      final feed = ValueNotifier<Brightness>(Brightness.dark);
      final runtime = MCPUIRuntime();
      addTearDown(() {
        runtime.engine.themeManager.setHostBrightness(null);
        feed.dispose();
      });
      final s = AppSessionImpl(
        handle: const AppHandle.bundle('com.example.theme'),
        runtime: runtime,
        conn: ConnectionManager(),
        runtimeManager: RuntimeManager(),
        toolDispatcher: ToolDispatcher(),
        resourceSubscriber: ResourceSubscriber(),
        logger: NoopLogger(),
        hostBrightness: feed,
      );

      late BuildContext ctx;
      await tester.pumpWidget(
        Builder(builder: (c) {
          ctx = c;
          return const SizedBox();
        }),
      );

      // Leftover state: some other runtime widget's dispose cleared the
      // global pin after the previous app closed.
      runtime.engine.themeManager.setHostBrightness(null);
      expect(runtime.engine.themeManager.flutterThemeMode,
          isNot(ThemeMode.dark));

      // Entering the app must re-pin from the live feed BEFORE building —
      // even though the runtime itself is uninitialized (throws after the
      // re-injection step).
      try {
        s.buildWidget(context: ctx);
      } on StateError {
        // expected — runtime not initialized in this harness
      }
      expect(runtime.engine.themeManager.flutterThemeMode, ThemeMode.dark,
          reason: 'entry must push the current brightness, not trust '
              'whatever a previous mount left behind');
    });
  });

  group('AppSessionImpl — accessor surface', () {
    test('handle / source / bundle / metadata round-trip', () {
      const handle = AppHandle.bundle('com.example.x');
      final bundle = mb.McpBundle(
        manifest: mb.BundleManifest(id: 'b', name: 'b', version: '1'),
      );
      final s = _session(handle: handle, bundle: bundle);
      expect(s.handle, handle);
      expect(s.source, AppSource.bundle);
      expect(s.bundle, same(bundle));
      expect(s.metadata, isNull);
    });

    test('server-source session reports source=server', () {
      final s = _session(handle: const AppHandle.server('srv'));
      expect(s.source, AppSource.server);
      expect(s.bundle, isNull);
    });
  });

  group('AppSessionImpl.close', () {
    test('close is idempotent', () async {
      final s = _session();
      await s.close();
      await s.close(); // second call returns immediately, no error
    });

    test('close unregisters every JS tool name from the dispatcher',
        () async {
      final dispatcher = ToolDispatcher();
      dispatcher.registerInProcessTool('a', (_) async => null);
      dispatcher.registerInProcessTool('b', (_) async => null);

      final s = AppSessionImpl(
        handle: const AppHandle.bundle('b1'),
        runtime: MockMCPUIRuntime(),
        conn: ConnectionManager(),
        runtimeManager: RuntimeManager(),
        toolDispatcher: dispatcher,
        resourceSubscriber: ResourceSubscriber(),
        logger: NoopLogger(),
        jsToolNames: const ['a', 'b'],
      );
      await s.close();
      expect(dispatcher.inProcessToolNames, isEmpty);
    });

    test('close invokes the onClose hook', () async {
      var hookFired = false;
      final s = _session(onClose: () async {
        hookFired = true;
      });
      await s.close();
      expect(hookFired, isTrue);
    });

    test('close swallows onClose hook errors', () async {
      final s = _session(onClose: () async => throw StateError('boom'));
      await s.close(); // does not rethrow
    });

    test('close disposes the JS runtime (idempotent on its side)',
        () async {
      final runtime = JsToolRuntime();
      final s = AppSessionImpl(
        handle: const AppHandle.bundle('b1'),
        runtime: MockMCPUIRuntime(),
        conn: ConnectionManager(),
        runtimeManager: RuntimeManager(),
        toolDispatcher: ToolDispatcher(),
        resourceSubscriber: ResourceSubscriber(),
        logger: NoopLogger(),
        jsRuntime: runtime,
      );
      await s.close();
      expect(runtime.isDisposed, isTrue);
    });
  });
}
