import 'package:flutter_mcp_ui_runtime/flutter_mcp_ui_runtime.dart';
import 'package:mcp_client/mcp_client.dart';
import 'package:mocktail/mocktail.dart';

import 'package:appplayer_core/src/connection/connection_manager.dart';

class MockClient extends Mock implements Client {}

class MockMCPUIRuntime extends Mock implements MCPUIRuntime {}

class MockStateManager extends Mock implements StateManager {}

class MockConnectionManager extends Mock implements ConnectionManager {}
