import 'dart:async';

import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import '../logging/logger.dart';

/// Mirrors a bound device's state into its dashboard slot, both ways.
///
/// mcp_ui_dsl §3.5.5: a dashboard reads a device at `slot.<id>.<path>` and
/// controls it by writing the same path. That is what lets one device's
/// reading drive another device's control with nothing but the ordinary
/// binding and action vocabulary — no action needs a field naming a target,
/// because the **path** names it.
///
/// Before this, a slot carried only `deviceId`: the devices were mounted and
/// their values were nowhere the dashboard document could see them, so a
/// dashboard could place a device but never react to one.
class SlotStateBridge {
  SlotStateBridge({
    required MCPUIRuntime dashboard,
    required MCPUIRuntime device,
    required String slotId,
    Logger? logger,
  })  : _dashboard = dashboard,
        _device = device,
        _slotId = slotId,
        _logger = logger ?? NoopLogger();

  final MCPUIRuntime _dashboard;
  final MCPUIRuntime _device;
  final String _slotId;
  final Logger _logger;

  StreamSubscription<StateChangeEvent>? _fromDevice;
  StreamSubscription<StateChangeEvent>? _fromDashboard;

  /// Paths the host owns. A device naming one of these in its own state must
  /// not be able to rewrite what the host said about the binding.
  static const _hostOwned = <String>{'deviceId', 'error'};

  String get _prefix => 'slot.$_slotId.';

  /// Breaks the echo a two-way mirror produces.
  ///
  /// A synchronous "currently applying" flag does not work here: both streams
  /// are broadcast and deliver asynchronously, so the flag is already cleared
  /// by the time the other side hears about the write, and the two sides bounce
  /// the same value between them forever. Comparing against the value already
  /// held is what actually terminates — a mirror that has nothing to change
  /// stops.
  static bool _same(dynamic a, dynamic b) {
    if (identical(a, b)) return true;
    if (a is num && b is num) return a == b;
    return a == b;
  }

  void start() {
    // Seed: whatever the device already holds becomes visible at once, so a
    // dashboard that renders before the first change is not empty.
    _device.stateManager.state.forEach((key, value) {
      if (_hostOwned.contains(key)) return;
      _setDashboard('$_prefix$key', value);
    });

    _fromDevice = _device.stateManager.stream.listen((event) {
      final path = event.path;
      if (_hostOwned.contains(path.split('.').first)) return;
      _setDashboard('$_prefix$path', event.newValue);
    });

    _fromDashboard = _dashboard.stateManager.stream.listen((event) {
      if (!event.path.startsWith(_prefix)) return;
      final devicePath = event.path.substring(_prefix.length);
      if (devicePath.isEmpty) return;
      // `deviceId` / `error` describe the binding, not the device.
      if (_hostOwned.contains(devicePath.split('.').first)) return;
      if (_same(_device.stateManager.get<dynamic>(devicePath), event.newValue)) {
        return;
      }
      try {
        _device.stateManager.set(devicePath, event.newValue);
      } catch (e) {
        _logger.warn('dashboard.slot.write_failed', {
          'slotId': _slotId,
          'path': devicePath,
        }, e);
      }
    });
  }

  void _setDashboard(String path, dynamic value) {
    if (_same(_dashboard.stateManager.get<dynamic>(path), value)) return;
    try {
      _dashboard.stateManager.set(path, value);
    } catch (e) {
      _logger.warn('dashboard.slot.mirror_failed', {
        'slotId': _slotId,
        'path': path,
      }, e);
    }
  }

  Future<void> dispose() async {
    await _fromDevice?.cancel();
    await _fromDashboard?.cancel();
    _fromDevice = null;
    _fromDashboard = null;
  }
}
