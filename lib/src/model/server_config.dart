import 'package:uuid/uuid.dart';

/// Supported MCP transport types.
enum TransportType {
  stdio,
  sse,
  streamableHttp,
}

extension TransportTypeName on TransportType {
  /// Human-readable display name used in UI/logging.
  String get displayName {
    switch (this) {
      case TransportType.stdio:
        return 'STDIO (Process)';
      case TransportType.sse:
        return 'SSE (Server-Sent Events)';
      case TransportType.streamableHttp:
        return 'HTTP (Streamable)';
    }
  }
}

/// Server configuration persisted by the host.
class ServerConfig {
  ServerConfig({
    String? id,
    required this.name,
    required this.description,
    required this.transportType,
    required this.transportConfig,
    DateTime? createdAt,
    this.lastConnectedAt,
    this.isFavorite = false,
    this.metadata,
  })  : id = id ?? const Uuid().v4(),
        createdAt = createdAt ?? DateTime.now();

  final String id;
  final String name;
  final String description;
  final TransportType transportType;
  final Map<String, dynamic> transportConfig;
  final DateTime createdAt;
  final DateTime? lastConnectedAt;
  final bool isFavorite;
  final Map<String, dynamic>? metadata;

  /// Migrate legacy transport type names.
  static TransportType _parseTransportType(String raw) {
    switch (raw) {
      case 'tcp':
      case 'websocket':
        return TransportType.sse;
      case 'http':
        return TransportType.streamableHttp;
      default:
        return TransportType.values.firstWhere(
          (e) => e.name == raw,
          orElse: () => TransportType.stdio,
        );
    }
  }

  factory ServerConfig.fromJson(Map<String, dynamic> json) {
    return ServerConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String,
      transportType:
          _parseTransportType(json['transportType'] as String),
      transportConfig:
          Map<String, dynamic>.from(json['transportConfig'] as Map),
      createdAt: DateTime.parse(json['createdAt'] as String),
      lastConnectedAt: json['lastConnectedAt'] != null
          ? DateTime.parse(json['lastConnectedAt'] as String)
          : null,
      isFavorite: json['isFavorite'] as bool? ?? false,
      metadata: json['metadata'] == null
          ? null
          : Map<String, dynamic>.from(json['metadata'] as Map),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'transportType': transportType.name,
      'transportConfig': transportConfig,
      'createdAt': createdAt.toIso8601String(),
      'lastConnectedAt': lastConnectedAt?.toIso8601String(),
      'isFavorite': isFavorite,
      'metadata': metadata,
    };
  }

  ServerConfig copyWith({
    String? name,
    String? description,
    TransportType? transportType,
    Map<String, dynamic>? transportConfig,
    DateTime? lastConnectedAt,
    bool? isFavorite,
    Map<String, dynamic>? metadata,
  }) {
    return ServerConfig(
      id: id,
      name: name ?? this.name,
      description: description ?? this.description,
      transportType: transportType ?? this.transportType,
      transportConfig: transportConfig ?? this.transportConfig,
      createdAt: createdAt,
      lastConnectedAt: lastConnectedAt ?? this.lastConnectedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      metadata: metadata ?? this.metadata,
    );
  }
}
