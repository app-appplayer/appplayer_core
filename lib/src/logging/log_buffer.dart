import 'package:flutter/foundation.dart';
import 'package:mcp_client/mcp_client.dart' show McpLogLevel;

import 'log_entry.dart';

/// Ring buffer of recent [LogEntry] records — exposed as a
/// `ChangeNotifier` so an in-app viewer rebuilds on every push.
///
/// Holds both [LogSource.core] (AppPlayer diagnostics, fed by
/// `BufferLogger`) and [LogSource.mcp] (server-emitted
/// `notifications/message`, fed by the host's `onMcpLogMessage`
/// callback) so production users can export everything for issue
/// reports from a single place.
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.capacity = 1000})
      : assert(capacity > 0, 'LogBuffer capacity must be positive');

  final int capacity;
  final List<LogEntry> _entries = <LogEntry>[];

  /// Read-only snapshot (oldest first).
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  void add(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    notifyListeners();
  }

  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  Iterable<LogEntry> filter(bool Function(LogEntry entry) test) =>
      _entries.where(test);

  Iterable<LogEntry> withSource(LogSource source) =>
      _entries.where((e) => e.source == source);

  Iterable<LogEntry> withScope(String key, Object? value) =>
      _entries.where((e) => e.context[key] == value);

  Iterable<LogEntry> atLeast(McpLogLevel minLevel) =>
      _entries.where((e) => e.level.index >= minLevel.index);
}
