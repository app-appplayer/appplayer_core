import 'package:mcp_client/mcp_client.dart' show McpLogLevel;

import 'logger.dart';

/// Origin of a [LogEntry] — distinguishes AppPlayer's own diagnostic
/// trace from MCP server-emitted `notifications/message` payloads so
/// the field-report viewer can separate them.
/// Where a record came from.
///
/// `runtime` is the UI DSL runtime. Its diagnostics used to go to
/// `dart:developer` and stop there: whoever had DevTools open saw them and
/// nobody else. Some of them are addressed to the person who wrote the
/// document — "this theme role was declared and dropped" — and that person is
/// looking at the app, not at a debugger.
enum LogSource { core, mcp, runtime }

/// Single record stored in [LogBuffer]. Both AppPlayer Core diagnostics
/// (via `BufferLogger`) and MCP server logs (via `notifications/message`)
/// land here so a production user has one place to export when filing
/// an issue. The viewer filters by [source] / [level] / [scope].
///
/// `level` is RFC 5424 8-level (MCP standard) — preserved verbatim from
/// MCP payloads, mapped from AppPlayer's 4-level diagnostic enum for
/// core entries (see [LogEntry.fromCore]).
class LogEntry {
  LogEntry({
    DateTime? timestamp,
    required this.source,
    required this.level,
    required this.message,
    Map<String, Object?> context = const <String, Object?>{},
    this.error,
    this.stackTrace,
  })  : timestamp = timestamp ?? DateTime.now(),
        context = Map<String, Object?>.unmodifiable(context);

  /// AppPlayer Core diagnostic — maps the 4-level [LogLevel] into the
  /// corresponding MCP level (debug→debug, info→info, warn→warning,
  /// error→error) so a single viewer can show both sources uniformly.
  factory LogEntry.fromCore({
    DateTime? timestamp,
    required LogLevel level,
    required String message,
    Map<String, Object?> context = const <String, Object?>{},
    Object? error,
    StackTrace? stackTrace,
  }) {
    return LogEntry(
      timestamp: timestamp,
      source: LogSource.core,
      level: _coreToMcp(level),
      message: message,
      context: context,
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// A record from the UI DSL runtime (`MCPLogger`).
  ///
  /// The runtime's four levels map onto the same MCP levels the other two
  /// sources use, so one viewer shows all three without the reader having to
  /// know which subsystem spoke.
  factory LogEntry.fromRuntime({
    DateTime? timestamp,
    required String level,
    required String logger,
    required String message,
    Object? error,
    StackTrace? stackTrace,
  }) {
    return LogEntry(
      timestamp: timestamp,
      source: LogSource.runtime,
      level: _runtimeToMcp(level),
      message: '[$logger] $message',
      error: error,
      stackTrace: stackTrace,
    );
  }

  /// MCP server `notifications/message` payload (`{level, logger?, data?}`).
  /// Unknown / missing `level` falls back to `info` per spec convention.
  factory LogEntry.fromMcp({
    required String serverId,
    required Map<String, dynamic> params,
    DateTime? timestamp,
  }) {
    final raw = (params['level'] as String?)?.toLowerCase();
    final level = _parseMcpLevel(raw);
    final loggerName = params['logger'] as String?;
    final data = params['data'];
    final message = data is String
        ? data
        : (data == null ? '' : data.toString());
    return LogEntry(
      timestamp: timestamp,
      source: LogSource.mcp,
      level: level,
      message: loggerName == null ? message : '[$loggerName] $message',
      context: <String, Object?>{
        'serverId': serverId,
        if (loggerName != null) 'logger': loggerName,
        if (data is Map) ...data.cast<String, Object?>(),
      },
    );
  }

  final DateTime timestamp;
  final LogSource source;
  final McpLogLevel level;
  final String message;
  final Map<String, Object?> context;
  final Object? error;
  final StackTrace? stackTrace;

  /// Convenience accessor — equivalent to `context[key]`.
  Object? scope(String key) => context[key];

  static McpLogLevel _coreToMcp(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return McpLogLevel.debug;
      case LogLevel.info:
        return McpLogLevel.info;
      case LogLevel.warn:
        return McpLogLevel.warning;
      case LogLevel.error:
        return McpLogLevel.error;
    }
  }

  /// `MCPLogger` names its levels `DEBUG` / `INFO` / `WARN` / `ERROR`.
  static McpLogLevel _runtimeToMcp(String level) {
    switch (level.toUpperCase()) {
      case 'DEBUG':
        return McpLogLevel.debug;
      case 'WARN':
        return McpLogLevel.warning;
      case 'ERROR':
        return McpLogLevel.error;
      default:
        return McpLogLevel.info;
    }
  }

  static McpLogLevel _parseMcpLevel(String? name) {
    if (name == null) return McpLogLevel.info;
    for (final l in McpLogLevel.values) {
      if (l.name == name) return l;
    }
    return McpLogLevel.info;
  }
}
