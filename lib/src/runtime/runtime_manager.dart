import 'package:flutter/foundation.dart';
import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';

import '../logging/logger.dart';
import '../session/app_handle.dart';

/// Owns the lifecycle of per-[AppHandle] [MCPUIRuntime] instances
/// (MOD-RUNTIME-001, FR-RUNTIME-001~004).
///
/// Keying on [AppHandle] separates `server:` and `bundle:` namespaces so the
/// same id string cannot collide across sources (FR-SESSION-006).
class RuntimeManager extends ChangeNotifier {
  RuntimeManager({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;
  final Map<AppHandle, MCPUIRuntime> _runtimes = {};

  Map<AppHandle, MCPUIRuntime> get runtimes => Map.unmodifiable(_runtimes);

  MCPUIRuntime? getRuntime(AppHandle handle) => _runtimes[handle];

  bool hasRuntime(AppHandle handle) => _runtimes.containsKey(handle);

  /// FR-RUNTIME-001
  MCPUIRuntime getOrCreateRuntime(AppHandle handle) {
    final existing = _runtimes[handle];
    if (existing != null) {
      _logger.debug('Reusing runtime', {'handle': handle.toString()});
      return existing;
    }
    _logger.debug('Creating runtime', {'handle': handle.toString()});
    final runtime = MCPUIRuntime();
    _runtimes[handle] = runtime;
    notifyListeners();
    return runtime;
  }

  /// FR-RUNTIME-003
  Future<void> removeRuntime(AppHandle handle) async {
    final runtime = _runtimes[handle];
    if (runtime == null) return;
    _logger.debug('Removing runtime', {'handle': handle.toString()});
    try {
      await runtime.destroy();
    } catch (e, st) {
      _logger.logError('Runtime destroy failed', e, st,
          {'handle': handle.toString()});
    }
    _runtimes.remove(handle);
    notifyListeners();
  }

  /// FR-RUNTIME-004
  Future<void> removeAllRuntimes() async {
    _logger.debug('Removing all runtimes',
        {'count': _runtimes.length});
    for (final entry in _runtimes.entries.toList()) {
      try {
        await entry.value.destroy();
      } catch (e, st) {
        _logger.logError('Runtime destroy failed', e, st,
            {'handle': entry.key.toString()});
      }
    }
    _runtimes.clear();
    notifyListeners();
  }
}
