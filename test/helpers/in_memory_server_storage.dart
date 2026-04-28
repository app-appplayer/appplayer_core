import 'package:appplayer_core/src/model/server_config.dart';
import 'package:appplayer_core/src/storage/server_storage.dart';

/// Test-only in-memory implementation of [ServerStorage].
///
/// Satisfies the full contract defined in `docs/04_TEST/storage-server-storage.md`.
class InMemoryServerStorage implements ServerStorage {
  final Map<String, ServerConfig> _servers = {};

  @override
  Future<List<ServerConfig>> getServers() async =>
      List.unmodifiable(_servers.values);

  @override
  Future<ServerConfig?> getById(String id) async => _servers[id];

  @override
  Future<void> saveServer(ServerConfig server) async {
    _servers[server.id] = server;
  }

  @override
  Future<void> deleteServer(String id) async {
    _servers.remove(id);
  }

  @override
  Future<void> updateLastConnected(String id, DateTime at) async {
    final existing = _servers[id];
    if (existing == null) return;
    _servers[id] = existing.copyWith(lastConnectedAt: at);
  }

  @override
  Future<void> toggleFavorite(String id) async {
    final existing = _servers[id];
    if (existing == null) return;
    _servers[id] = existing.copyWith(isFavorite: !existing.isFavorite);
  }
}
