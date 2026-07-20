import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import 'package:appplayer_core/src/connection/connection_manager.dart';

class MockClient extends Mock implements Client {}

/// A [MockClient] with the `onDisconnect` liveness stream pre-stubbed to a
/// never-firing broadcast stream. [ConnectionManager.connect] subscribes to it
/// to clear dead connections; tests that don't exercise a drop just need it to
/// exist. Tests that DO simulate a transport drop should build their own client
/// and stub `onDisconnect` with a controller they can add to.
MockClient mockClient() {
  final client = MockClient();
  when(() => client.onDisconnect)
      .thenAnswer((_) => const Stream<DisconnectReason>.empty());
  return client;
}

class MockMCPUIRuntime extends Mock implements MCPUIRuntime {}

class MockStateManager extends Mock implements StateManager {}

class MockConnectionManager extends Mock implements ConnectionManager {}
