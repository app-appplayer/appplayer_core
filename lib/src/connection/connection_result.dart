import 'connection_info.dart';

/// Result of a [ConnectionManager.connect] attempt.
sealed class ConnectionResult {
  const ConnectionResult();

  factory ConnectionResult.success(ConnectionInfo connection) =
      ConnectionSuccess;
  factory ConnectionResult.failure(String error) = ConnectionFailure;

  bool get success;
  ConnectionInfo? get connection;
  String? get error;
}

final class ConnectionSuccess extends ConnectionResult {
  const ConnectionSuccess(this._info);
  final ConnectionInfo _info;

  @override
  bool get success => true;

  @override
  ConnectionInfo? get connection => _info;

  @override
  String? get error => null;
}

final class ConnectionFailure extends ConnectionResult {
  const ConnectionFailure(this._error);
  final String _error;

  @override
  bool get success => false;

  @override
  ConnectionInfo? get connection => null;

  @override
  String? get error => _error;
}
