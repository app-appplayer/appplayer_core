import '../model/server_config.dart';

/// Host-injected storage interface (MOD-STOR-001, FR-STOR-001~006).
///
/// The core does not ship a default implementation — the host application
/// provides one backed by SharedPreferences, SQLite, Firestore, etc.
abstract class ServerStorage {
  /// FR-STOR-001
  Future<List<ServerConfig>> getServers();

  /// Convenience single-record lookup.
  Future<ServerConfig?> getById(String id);

  /// FR-STOR-002 — insert if missing, update if present.
  Future<void> saveServer(ServerConfig server);

  /// FR-STOR-003 — idempotent; missing id is a no-op.
  Future<void> deleteServer(String id);

  /// FR-STOR-004 — no-op when id is unknown.
  Future<void> updateLastConnected(String id, DateTime at);

  /// FR-STOR-005 — no-op when id is unknown.
  Future<void> toggleFavorite(String id);
}
