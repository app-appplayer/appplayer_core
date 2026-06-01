import 'package:appplayer_core/internals.dart';
import 'package:appplayer_core/src/logging/logger.dart';
import 'package:appplayer_core/src/session/app_handle.dart';
import 'package:appplayer_core/src/session/app_session_impl.dart';
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
