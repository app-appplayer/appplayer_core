# AppPlayer Core

Shared Flutter library for AppPlayer — MCP server connection, bundle handling, and UI runtime orchestration. The single dependency surface for `appplayer_*` shells (Standard / Pro / X / Custom).

## Features

- **AppPlayerCoreService** — single orchestrator that owns the connection lifecycle, app/dashboard sessions, bundle install pipeline, and tool dispatch.
- **Session model** — `AppSession`, `DashboardSession`, `AppHandle` provide the public surface for a running app or dashboard.
- **Connection observability** — `ConnectionInfo`, `ConnectionResult`, `ConnectionState`, `ConnectionHealthMonitor` for connection status + auto-recovery.
- **Bundle handles + host ports** — `BundleRef`, `BundleEntryPoint`, `BundleFetcher`, `InstalledAppBundle`, plus dashboard bundle composition.
- **Apps registry** — `AppsRegistry` is the single source of truth for registered apps; `RegistryMetadataSink` keeps metadata fresh automatically.
- **Tenant model** — `TenantContext`, `TenantSource` for multi-tenant variants.
- **Host ports** — `ServerStorage`, `CredentialVault`, `AppMetadataSink`, observability `Logger` and `MetricsPort`.
- **Form-factor + responsive tokens** — re-exports `FormFactor`, `AppSpacing/Icons/Typography/Density` and the M3 DSL version constant from `flutter_mcp_ui_runtime` so hosts can stay on `appplayer_core` only.
- **Trust levels** — re-exported `TrustLevel` / `TrustLevelManager` for permission enforcement.

## Public surface

The barrel `package:appplayer_core/appplayer_core.dart` is **semver-tracked**. Internal wiring (ConnectionManager, RuntimeManager, ToolDispatcher, etc.) lives in `package:appplayer_core/internals.dart` for advanced hosts and is not semver-stable.

## Quick Start

```dart
import 'package:appplayer_core/appplayer_core.dart';

final core = AppPlayerCoreService(
  appsRegistry: AppsRegistry(),
  serverStorage: myServerStorage,
  credentialVault: myCredentialVault,
);

// Connect to an MCP server
final result = await core.connect(
  ServerConfig(
    id: 'my_server',
    transport: TransportType.streamableHttp,
    url: 'https://my-mcp-server.example/mcp',
  ),
);

// Open an app session
final app = await core.openApp(serverId: 'my_server', appId: 'my_app');
```

## Support

- [Issue Tracker](https://github.com/app-appplayer/appplayer_core/issues)
- [Discussions](https://github.com/app-appplayer/appplayer_core/discussions)

## License

MIT — see [LICENSE](LICENSE).
