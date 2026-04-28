import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import '../connection/connection_manager.dart';
import '../exceptions.dart';
import '../logging/logger.dart';
import '../session/app_handle.dart';
import '../runtime/notification_router.dart';
import '../runtime/resource_subscriber.dart';
import '../runtime/runtime_manager.dart';
import '../storage/server_storage.dart';
import 'dashboard_bundle.dart';
import 'dashboard_bundle_loader.dart';
import 'slot_binder.dart';
import 'summary_view_resolver.dart';

/// Composes Dashboard Mode: loads a bundle, binds slots to devices,
/// mounts each device's summary view (MOD-DASH-001, FR-DASH-001, 007~008).
class DashboardOrchestrator {
  DashboardOrchestrator({
    required ConnectionManager conn,
    required RuntimeManager runtime,
    required DashboardBundleLoader bundleLoader,
    required SlotBinder binder,
    required SummaryViewResolver summaryResolver,
    required ResourceSubscriber resourceSub,
    required NotificationRouter notifRouter,
    required ServerStorage storage,
    Logger? logger,
  })  : _conn = conn,
        _runtime = runtime,
        _bundleLoader = bundleLoader,
        _binder = binder,
        _summaryResolver = summaryResolver,
        _resourceSub = resourceSub,
        _notifRouter = notifRouter,
        _storage = storage,
        _logger = logger ?? NoopLogger();

  final ConnectionManager _conn;
  final RuntimeManager _runtime;
  final DashboardBundleLoader _bundleLoader;
  final SlotBinder _binder;
  final SummaryViewResolver _summaryResolver;
  // Reserved for future slot-level subscribe integration.
  // ignore: unused_field
  final ResourceSubscriber _resourceSub;
  final NotificationRouter _notifRouter;
  final ServerStorage _storage;
  final Logger _logger;

  MCPUIRuntime? _currentRuntime;
  DashboardBundle? _currentBundle;

  MCPUIRuntime? get current => _currentRuntime;

  /// FR-DASH-001
  Future<MCPUIRuntime> open(
    DashboardBundleRef ref,
    List<String> deviceIds,
  ) async {
    if (_currentRuntime != null) {
      await close();
    }

    final bundle = await _bundleLoader.load(
      ref,
      connectedDevices: deviceIds,
    );

    final runtimeHandle = _runtimeHandle(bundle.id);
    final runtime = _runtime.getOrCreateRuntime(runtimeHandle);
    if (!runtime.isInitialized) {
      await runtime.initialize(bundle.mainLayout);
    }

    final metadataByDevice = <String, Map<String, dynamic>>{};
    for (final id in deviceIds) {
      final config = await _storage.getById(id);
      if (config?.metadata != null) {
        metadataByDevice[id] = config!.metadata!;
      }
    }

    List<SlotBinding> bindings;
    try {
      bindings = _binder.bind(
        slots: bundle.slots,
        deviceIds: deviceIds,
        deviceMetadata: metadataByDevice,
      );
    } catch (e) {
      rethrow;
    }

    for (final binding in bindings) {
      try {
        await _mountSlot(runtime, bundle, binding);
      } on AppPlayerException catch (e) {
        _logger.warn('Slot mount failed', {
          'slotId': binding.slotId,
          'deviceId': binding.deviceId,
        }, e);
        runtime.stateManager.set('slot.${binding.slotId}.error',
            e.toString());
      }
    }

    _currentRuntime = runtime;
    _currentBundle = bundle;
    return runtime;
  }

  Future<void> _mountSlot(
    MCPUIRuntime dashRuntime,
    DashboardBundle bundle,
    SlotBinding binding,
  ) async {
    final server = await _storage.getById(binding.deviceId);
    if (server == null) {
      throw ServerNotFoundException(binding.deviceId);
    }

    final result = await _conn.connect(server);
    if (!result.success || result.connection?.client == null) {
      throw ConnectionFailedException(
        binding.deviceId,
        result.error ?? 'Unknown connection failure',
      );
    }
    final client = result.connection!.client!;

    final deviceRuntimeHandle = _deviceSummaryHandle(binding.deviceId);
    final deviceRuntime = _runtime.getOrCreateRuntime(deviceRuntimeHandle);

    final slotDef = bundle.slots.firstWhere(
      (s) => s.slotId == binding.slotId,
    );
    final summaryDef = await _summaryResolver.fetch(
      client,
      customUri: slotDef.summaryUri,
    );

    if (!deviceRuntime.isInitialized) {
      await deviceRuntime.initialize(summaryDef);
    }
    _notifRouter.register(client: client, runtime: deviceRuntime);

    dashRuntime.stateManager.set(
      'slot.${binding.slotId}.deviceId',
      binding.deviceId,
    );
  }

  /// FR-DASH-008
  Future<void> close() async {
    final bundle = _currentBundle;
    if (bundle == null) {
      _currentRuntime = null;
      return;
    }
    await _runtime.removeRuntime(_runtimeHandle(bundle.id));
    _currentRuntime = null;
    _currentBundle = null;
    _logger.info('Dashboard closed');
  }

  /// Helper exposed for [AppPlayerCoreService] to derive the summary
  /// runtime handle consistently.
  static AppHandle deviceSummaryRuntimeHandle(String deviceId) =>
      _deviceSummaryHandle(deviceId);

  static AppHandle _runtimeHandle(String bundleId) =>
      AppHandle.bundle('dashboard:$bundleId');

  static AppHandle _deviceSummaryHandle(String deviceId) =>
      AppHandle.server('$deviceId:summary');
}
