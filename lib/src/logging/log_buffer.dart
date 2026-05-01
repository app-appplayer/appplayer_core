import 'package:flutter/foundation.dart';

import 'log_entry.dart';
import 'logger.dart';

/// In-memory ring buffer that accumulates [LogEntry] records up to
/// [capacity] and notifies listeners on every change.
///
/// Tier shells (Pro / X / Custom / dev tooling) read this buffer to render
/// log viewers; the core library never reads it back. A single buffer can
/// be filtered per scope by callers — see [filter] and [LogEntry.scope].
class LogBuffer extends ChangeNotifier {
  LogBuffer({this.capacity = 1000})
      : assert(capacity > 0, 'LogBuffer capacity must be positive');

  final int capacity;
  final List<LogEntry> _entries = <LogEntry>[];

  /// Read-only snapshot of current entries (oldest first).
  List<LogEntry> get entries => List<LogEntry>.unmodifiable(_entries);

  /// Append [entry], evicting the oldest record once [capacity] is reached.
  void add(LogEntry entry) {
    _entries.add(entry);
    if (_entries.length > capacity) {
      _entries.removeAt(0);
    }
    notifyListeners();
  }

  /// Drop every recorded entry.
  void clear() {
    if (_entries.isEmpty) return;
    _entries.clear();
    notifyListeners();
  }

  /// Iterate entries matching [test] (oldest first).
  Iterable<LogEntry> filter(bool Function(LogEntry entry) test) =>
      _entries.where(test);

  /// Convenience filter — entries whose `context[key] == value`.
  Iterable<LogEntry> withScope(String key, Object? value) =>
      _entries.where((e) => e.context[key] == value);

  /// Convenience filter — entries at or above [minLevel].
  Iterable<LogEntry> atLeast(LogLevel minLevel) =>
      _entries.where((e) => e.level.index >= minLevel.index);
}
