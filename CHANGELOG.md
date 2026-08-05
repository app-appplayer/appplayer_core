## [0.1.20] - 2026-08-05 — floors move to the spec 1.4.1 cut

No source change in this package. The floors move because a caret bound on a
`0.x` minor cannot reach the next one, so without this bump a consumer of
`appplayer_core` keeps resolving the previous runtime and never sees the cut:

- `flutter_mcp_ui_core` — the registry narrows in four places (retired legacy
  enum spellings on `linear.distribution` and `qrCode.errorCorrection`, the
  `otpInput.autoSubmit` property, and a required `value` on option objects),
  which is what makes that release a minor rather than a patch.
- `flutter_mcp_ui_runtime` — vector assets (SVG) draw in every `AssetRef`
  slot including `icon`, union-typed slots read every branch they declare
  (`Dimension` objects, action lists, bindings in enum and `EdgeInsets`
  slots), ink overlays paint above what the document paints, and ten declared
  properties gained implementations. Brings `flutter_svg` transitively.

Consumers that pin `appplayer_core` need only this bump; the surface they
compile against is unchanged.

## [0.1.19] - 2026-08-03 — mcp_ui 1.4 cut

Floors `flutter_mcp_ui_core ^0.4.3 → ^0.5.0` and
`flutter_mcp_ui_runtime ^0.5.3 → ^0.6.0`.

Both are minor because the schema narrows: `AssetRef` slots reject a bare
string carrying no scheme, the icon slots take the new `IconRef`, and thirteen
string properties that documented their values in prose now declare `enum`. A
caret bound on `^0.5.x` cannot reach 0.6.0, so this floor is what lets any
AppPlayer tier see the new runtime at all.

What arrives with it: one asset resolution path for every `AssetRef` slot
(`image` / `avatar` / `icon` / `box.decoration` converge, and `bundle://` and
`client://` are resolvable for the first time), `navigation.openUrl`, and 23
new widgets. No API in this package changed — the surface is identical and the
bump is the dependency cut.

## 0.1.18 - 2026-08-02 - Install into host-provided storage; streams survive a background resume

### Added
- `AppPlayerCoreService.installBundleFromBytes` — install from `.mcpb`
  bytes already in hand. A host that fetched the archive itself has bytes
  and never a path; `installBundleFromFile` is the same call with a read
  in front of it.
- `AppPlayerCoreService` `bundleInstallStore:` — install into and read
  installed bundles from host-provided storage instead of a directory.
  When given, `bundleInstallRoot` is not used as one.
- `BundleInstallerAdapter.onStore` and `BundleLoaderAdapter(installStore:)`
  — the same seam one layer down.

### Changed
- `BundleApplicationAdapter` requires the bundle to carry readable files,
  not a filesystem directory. A bundle installed into host storage now
  adapts; previously it was refused outright with
  `BundleAdaptException(unsupportedEntryPoint)` before anything was read.
- JS tool entry scripts are read through the bundle's own file surface
  rather than `File(<directory>/<entry>)`, so bundles that carry JS tools
  work on hosts with no filesystem.

Desktop and mobile behaviour is unchanged — omit `bundleInstallStore` and
the filesystem path is taken exactly as before.

### Fixed
- An app left open across a background round trip stopped streaming. A
  subscription and a notification handler both live on the CONNECTION, and
  mobile tears the connection down in the background and rebuilds it with a
  NEW client on return. Tool calls kept working (those resolve the live
  client per call), so the screen looked healthy while only the stream was
  dead — and pressing Subscribe again did nothing, because the runtime
  binding had never been lost and there was nothing left for the runtime to
  do. Re-attached on the new client:
  - `ConnectionManager.onClientAttached` — hook fired whenever a server's
    client is replaced (first connect included).
  - `ResourceSubscriber.reattach` — re-issues the wire `resources/subscribe`
    for every URI recorded under an `ownerKey`, plus the initial read so the
    first value after a resume is current rather than the frozen one.
    Bindings are NOT re-registered; they never went away.
  - `AppPlayerCoreService` wires the two, covering the full-screen app AND
    the dashboard's per-device summary runtime (a composed tile watching the
    same device is otherwise the one surface still frozen).

## 0.1.17 - 2026-08-02 - Boot on the web

### Fixed
- `initialize` threw `Unsupported operation: Platform._operatingSystem` on the
  web and took the whole host down before the first frame — a blank page. One
  line built the `LifecycleCoordinator` with
  `platformSuspends: Platform.isAndroid || Platform.isIOS`, and `Platform` is
  `dart:io`. It is now `!kIsWeb && (...)`.

  `false` is the truthful value on the web rather than a way around the throw:
  a tab has no process to suspend, and no native background port is injected
  for continuity to pause against. The value was also **not injectable** — the
  coordinator takes the flag but `initialize` hardcoded it, so a host could not
  work around this from outside. The neighbouring ports (`backgroundPort`,
  `permissionPort`, `notificationPort`) all have seams and web hosts had
  already passed them by injecting no-ops; this was the next line.

  Reported against a release web build with source maps, so the frame was the
  line and not a guess.

### Verified

Against the real app, both directions. `appplayer_cloud` in Chrome resolving
this package from a local path booted with no exception; the same app with the
published 0.1.16 rendered its error screen naming
`app_player_core_service.dart 621:34`. Same app, same browser, one line
different.

### Not in this release — the browser regression

A `@TestOn('browser')` boot regression is written
(`test/integration/web_boot_test.dart`) and is **skipped**, because it hangs:
headless Chrome loads and `initialize` never completes there, while the same
`initialize` completes in the real app. The difference is what a host injects,
so the harness — not the fix — is what is unfinished. It ships skipped with
that reason attached rather than deleted, because the gap it names is real:
every other test that calls `initialize` runs on the VM, which is why a
`dart:io` call sat on the boot path unnoticed.

## 0.1.16 - 2026-07-29 - JavaScript tool runtime per platform

### Changed
- The per-bundle JavaScript runtime now resolves per platform. `JsToolIsolate`
  became a conditional export: the existing embedded-engine implementation on
  platforms with `dart:io`, and a Web Worker implementation elsewhere. The
  native implementation is the same code, relocated to `js_tool_isolate_io.dart`
  — no behavior change off the web.
- The JS-side host bridge contract moved to `src/js/js_bridge_protocol.dart` and
  is shared by both branches: `host.<atom>.<verb>()` returns a Promise resolved
  through `__hostResolve` / `__hostReject` exactly as before. Only the transport
  differs — an isolate port natively, `postMessage` on the web — so a bundle's
  JavaScript behaves identically on both.

### Added
- Web branch of the JS tool runtime. Bundle JavaScript runs in a Web Worker,
  never on the page: a Worker has its own global scope and no DOM, so the
  bundle cannot reach the document, application state, storage or cookies.
  Main-thread evaluation is not offered as an alternative path. Everything
  crossing the boundary is a JSON string, so a bundle cannot hand the host a
  live JavaScript object; a dispatcher error becomes a rejected Promise on the
  JS side rather than a runtime failure.
- `web` dependency, used only by that branch.

### Fixed
- The shared bootstrap parenthesises the transport call. A bare
  `function (p) {...}` in statement position parses as a function *declaration*
  and is rejected for having no name, so the host bridge failed to install.
  This was introduced by the refactor and reached the native branch too, where
  no test could see it — the embedded engine cannot start inside `flutter test`,
  so nothing had ever executed that bootstrap. The browser suite now evaluates
  the native variant of the string in a real engine, which closes that gap.

### Notes
- Hosting requirement for the web branch: the Worker is created from a blob, so
  the page policy must allow `worker-src blob:`, and the Worker needs
  `'unsafe-eval'` — executing caller-supplied JavaScript is the feature. This
  fails far from its cause, so it is also recorded in the source.
- This lifts `dart:ffi` out of the web dependency graph, which is what stopped
  `flutter build web` for any application depending on this package.

## 0.1.15 - 2026-07-28 - Multi-origin composition (MCP UI DSL v1.4 Composition Profile)

### Added — entry context on the open paths (platform spec 19 §4.3, MCP UI DSL §8.9)

- **`openAppFromServer(..., entry:, identity:)` and `openAppFromBundle(..., entry:, identity:)`** — carry how an app was reached and who is looking at it. An `entry` naming a route opens the app **on that page** instead of its own `initialRoute`, which is what lets a scanned code, a deep link, or an app-to-app open land where it asked. Both parameters are optional and absent for a launcher open, so every existing call is unchanged.
- Re-exports the entry value types (`EntryContext`, `EntryIssuer`, `EntryNotice`, `IdentityContext`, `IdentityState`, `IdentitySubjectKind`, `EntrySession`, `EntryStateKeys`) so a host consuming only `appplayer_core` can build them.

- **Deferred entry** (`DeferredEntryResolver`, `DeferredEntrySource`, `FirstLaunchStore`) — an entry that sent someone to an app store resumes on first launch (§3.5). The policy is pure and the platform pieces are injected, so the rules hold on a platform that can carry a code and on one that cannot.
  - **The absence of a source is meaningful.** A host with no mechanism supplies none, and that turns the obligation into an offer of manual recovery rather than silence. A source that answers "this install did not begin at an entry" produces nothing instead — prompting there would be a question about something that never happened.
  - A mechanism that threw is treated as a mechanism we do not have.
  - The launch is marked seen either way: a recovery offered twice is a nag, and a code recovered twice would reopen the same entry on a launch nobody connected to it.
- **`EntryOpener`** — turns a resolved target into an open session. Tiers differ in chrome, not in what a target means: "a server target is an endpoint you register and open" is the same sentence everywhere, so it stopped being rewritten per tier. A server learned from an entry is registered under an id derived from its endpoint, so scanning the same medium twice reuses one row instead of accumulating one per scan. `localServer` needs a discoverer the tier wires (discovery is a host capability); without one the entry fails visibly rather than dialling something else. A `listing` deliberately has no path to a screen here — acquisition is the marketplace's act, and a path from a listing id to a render would blur install and run.
- **`EntryLink.parse`** — reads the opaque code out of a claimed https link. Host matching is **exact**: a suffix match would accept `evil-entry.example.test` for `entry.example.test`, and a build resolving codes from a host it does not claim is resolving someone else's registry. Everything after the path prefix is the code, so an issuer may partition its code space however it likes and this side stays ignorant of the shape. A link this build does not claim is **rejected with a reason**, not swallowed — the host falls through to whatever it normally does with a URL.
- **Entry resolution pipeline** (`EntryResolverPort`, `EntryPipeline`, `EntryTarget` and friends) — the host side of platform spec 19. Every acquisition path (an intercepted link, a scanner, a deferred entry recovered after an install) produces the same code and takes this one path, so the rules hold whichever door the code came through. The resolver itself is a port: the platform never assumes where the medium registry lives.
  - **`canIdentify`** — a build with no sign-in refuses a `required` entry instead of rendering it as a guest. Answering a demand for identity by ignoring it produces a screen that looks like it worked, which is the failure mode this whole layer exists to prevent. Distinct from an unsupported target: the destination is fine, the viewer cannot be established.
  - Enforced here because each of these failures is invisible from the outside: a stale answer is never replayed (custody may have changed since it was minted), a guest entry never resolves to an account-gated target, and an entry this host cannot open is **reported rather than substituted** — a silently swapped target looks exactly like a working one.
  - Wire parsing defaults to the safe reading: an unknown `status` is not `ok`, and an unparsed `identityPolicy` demands identity rather than assuming guest. Guessing `open` would render a guest surface for an entry we failed to understand; guessing `required` merely asks someone to sign in.
  - `EntryTarget.toEntryContext()` is the only thing that crosses into the document — route, params, issuer, grant **scope**. The grant token and the medium's owner/holder never do.
- **`launchRoute:`** alongside `entry:` on both open paths. An in-app open (DSL §4.3.1 `navigation.openApp`) names a page without being an arrival, so it sets the route and leaves the document's `entry.*` tree absent (§8.9.1).
- **`AppSession.launchRouteMissing`** — true when the entry named a page this app no longer declares. Spec 19 §9.6 puts the disclosure on the host, and a host cannot render a log line; without a surface to read, "fell back" and "worked" are the same outcome from outside.

A route the app no longer declares is **not** honoured silently: the runtime falls back to the app's own initial route and the miss is logged (`entry.route.missing`) for the host to disclose. A stale binding that quietly renders the home page is indistinguishable from a working one, and bindings outlive app versions.

Re-opening a handle whose runtime is still alive adopts the newer entry. Without that the same medium scanned twice would render the first scan's context.

### Added
- **`openSavedDeviceAsOrigin(id)`** — opens a saved device as a composition origin through the same `ConnectionManager` the launcher uses, and **`adoptConnectionAsOrigin({id, client})`** under it. Origins used to be opened on a private stack while the launcher used its own, both keyed by the same device id, so neither could see the other's link: opening a device from a composed screen and then from its own app dialled twice, and the board — single-peer — refused the second with `Transport disconnected`. One connection per device now, shared by both.

### Fixed
- Opening a device's own screen silenced every composed tile watching the same device — permanently, and with nothing to show for it: the subscription stayed live, the socket stayed up, and closing the screen did not bring it back. `Client.onNotification` keeps one handler per method, so once one connection per device is shared the notification router took the slot from the kernel connection the tiles listen on. Both now register through `SharedClientNotifications`, which takes the slot once and fans out. Subscriptions are reference-counted the same way (`SharedResourceSubscriptions`), so one consumer releasing no longer stops the other's stream.
- A composed tile re-read the device's UI document on **every** mount. The connection was never dropped — the socket stayed up across open and close — but entering the screen again cost `ui://app` + `ui://page/main` over the wire, so the tile spun and looked like it was reconnecting while the standalone screen came back instantly. Resolved definitions are now cached per origin and dropped when the origin is (re)opened, which is the only moment the document can have changed: a device that rebooted with new UI necessarily got a new connection first. Measured after the fix: re-entry 1.1s against 1.2s for the first open, both tiles fully rendered. (Fixed in the `composition_host` recipe and re-vendored.)
- Composition treated "the host lists this connection id" as "the origin is
  open". A connection whose link had gone was still listed, so a composed tile
  decided it had nothing to open and never asked again while every call it made
  landed on a dead link — the device worked when opened on its own and never
  appeared in a multi-device screen. Openness is now decided by liveness.
  (Fixed in the `composition_host` recipe and re-vendored.)

### Added
- **`registerDefinitionResolver(resolve)`** — the host resolver behind a `view` / route `DefinitionSource` that names an origin. Registering it is how this host **claims** the Composition Profile; without it `view` fails closed and renders its `fallback` rather than resolving a foreign `$ref` against the app's own server (spec §18.7.3), which would put one device's UI under another's identity.
- **`useKernelDefinitionResolver({readOwn})`** — the canonical wiring, reading through the kernel's outbound `mcp.*` surface. Platform spec `06-tool-registry.md` already declares "the app/bundle drives `mcp.*` directly and fetches a resource (e.g. a dashboard UI)" as the default path, and those tools are already on this host's in-process dispatcher — so composition needs **no new transport, no new connection registry, and no manifest field**, only a reader. Parses the shape a board actually serves (`contents[0].text` carrying escaped JSON) and accepts an already-decoded map.
- The registered resolver is applied to every app/bundle runtime at creation, alongside the existing stream sources.
- **`openOrigin` hook** — a document names an origin; the host opens it on first use. Registering a device does not hold a connection open, and holding one would be wrong: several boards serve a single peer at a time, so a permanent connection each has the last one to connect reset the others.
- **Origin-scoped acting and watching** — the resolver wiring now also installs a tool caller and a resource watcher for a named origin. Rendering and acting are separate halves and only the first existed: a composed screen drew each device's UI while every control in it reached a session with no client for that device, and a live reading rendered its label and never a value. Tool calls go out as `mcp.call_tool` on the named connection; a watch reads the current value once (a subscription reports only *changes*) and then follows `notifications/resources/updated`.

### Security
- Fails closed by design: an empty origin with no `readOwn`, an unrecognised origin key, and an empty connection id all throw rather than falling back to the app's own server (spec §7.10.1 rule 6).

### Changed
- `flutter_mcp_ui_runtime` floor raised `^0.5.2 → ^0.5.3` (the `view` widget + `registerDefinitionResolver` seam).
- `brain_kernel` floor raised `^0.1.8 → ^0.2.0` (resource subscription on a kernel connection).

## 0.1.14 - 2026-07-22 - Durable reconnect (token re-grant seam)


Additive (0.x → patch). No public API removed.

- **Durable reconnect — `ServerReGrant` seam.** A marketplace server's credential
  is a short-lived per-user `connectionToken` baked into
  `ServerConfig.transportConfig`. When a connect attempt fails and the server
  carries a bearer token, `ConnectionManager` now calls an optional host-supplied
  re-grant hook, refreshes the token, and retries the connect once (the retry
  runs without re-grant so a persistently bad server can't loop). This closes the
  gap where opening a saved server app with an expired token 401'd until a manual
  reinstall — `openAppFromServer`, `reconnect()` and `ConnectionHealthMonitor` all
  funnel through `connect()`, so all three are covered.
  - New: `typedef ServerReGrant = Future<ServerConfig?> Function(ServerConfig stale)`
    (barrel-exported), `ConnectionManager.tokenReGrant` (mutable, optional),
    `AppPlayerCoreService.serverReGrant` setter (host wires it after the
    marketplace session exists).
  - **Fully backward-compatible**: when no hook is wired (or the server carries no
    bearer token) connect/reconnect behave byte-for-byte as before — static-token,
    hand-typed and discovered (tcp/ble/serial) servers are untouched.
- Doc hygiene: removed dangling doc/spec references (`docs/`, `specs/`, `spec §N`)
  from source comments so nothing points outside the published package. No code
  change.

## 0.1.13 - 2026-07-18 - Flutter-plugin promotion · metadata-only install · single-route apps · debug MCP · connection continuity

Additive across the tracks landed since 0.1.12. `^0.1.12` consumers pick these
up on floor-bump; no public API removed.

### Added
- **Flutter-plugin promotion (Platform Integration Foundation, FR-PLATFORM)** —
  `appplayer_core` declares a `flutter: plugin:` with native Android/iOS
  adapters (background execution, OS permission, notification); desktop/web
  degrade to the Dart ports' NoOp. `onLifecyclePhase(AppLifecyclePhase)` drives
  the foundation.
- **Metadata-only install** — `fetchServerMetadata(serverId)` /
  `fetchBundleMetadata(BundleRef)` read a card's name/icon WITHOUT rendering, so
  install ≠ run (the launcher tile is populated, the UI loads on first open).
- **Single-route application wrapping** — `AppLoader.wrapAsApplication(...)`
  promotes a bare served page into a single-route application (app name = page
  title), so a server app renders with the standard chrome (AppBar/Close) and no
  separate metadata serving.
- **Debug MCP host** — opt-in (`enableDebugMcp`, settings-gated, non-web) MCP
  server on `127.0.0.1:<port>/mcp` exposing `ui.screenshot` / `ui.tree` /
  `ui.tap` / `ui.type` for test automation; `debugCaptureWrap(child)` gives the
  capture/tap primitives a stable render boundary.
- **Connection continuity** — transport-drop handling (`_handleTransportDrop`
  with `DisconnectReason`) + `keepAliveSweep(...)` for reconnect/resume.

### Dependencies
- Floors raised to current latest at cut time: `mcp_client ^2.1.0`,
  `mcp_bundle ^0.4.8`, `flutter_mcp_ui_core ^0.4.1`,
  `flutter_mcp_ui_runtime ^0.5.1`, `brain_kernel ^0.1.8`.

## 0.1.12 - 2026-07-14 - Theme state rebuilt on every app entry

### Fixed
- `AppSession.buildWidget` / `buildDashboardWidget` rebuild the theme state on
  every entry: the runtime's ThemeManager is a process-wide singleton, so the
  previous app's palette/mode leaks into the next one and any runtime widget's
  dispose clears the brightness pin. Entry now applies the app's own declared
  theme — or a SYSTEM BASELINE with real light AND dark token sets — whenever
  ownership changes hands, then re-pins the current host brightness. The bare
  `defaultLight()` default has no dark tokens, which is why undeclared apps
  rendered "weird dark" on first entry until another app left a full palette
  behind in the singleton.
- The rebaseline skip-gate verifies the singleton's FINGERPRINT (not just an
  ownership tag): runtime teardown resets the ThemeManager behind the
  session's back (`MCPUIRuntime.destroy` → `reset()`), so a stale tag made
  same-app re-entry skip over the bare default — re-open of the same app
  rendered weird while a detour through another app healed it.

## 0.1.11 - 2026-07-13 - Marketplace connect credential + bundle cache invalidation

### Fixed
- streamableHttp transport carries `accessToken` as `Authorization: Bearer`
  (+ `headers` passthrough, explicit header wins); it was dropped entirely, so
  token-gated servers rejected the handshake (401 → "Transport disconnected").
- install/uninstall invalidate the bundle's session runtime + metadata caches
  (FR-INSTALL-009) — a reinstall/update no longer keeps rendering the old
  definition until app restart.

### Changed
- Floor `mcp_client ^2.0.1` (spec-optional `description` parse fix).

## 0.1.10 - 2026-07-12 - Extension-transport seam conformance (additive)

### Changed
- `AppPlayerCoreService.connectExtensionTransport` now delegates to the
  `brain_kernel` core `connectExtension(clientHost, …)` helper off the abstract
  `KernelClientHost`, dropping the redundant concrete `McpClientKernelHost`
  field/ref and the inline probe-and-cast (the `is`-no-promotion footgun is now
  sealed inside the kernel helper). Behaviour unchanged.
- Floors `brain_kernel ^0.1.2 → ^0.1.7` (the `ExtensionTransportConnect`
  capability interface + `connectExtension` helper). No API change to
  appplayer_core's own surface.

## 0.1.9 - 2026-06-22 - Capability tools registration seam (additive)

### Added
- `AppPlayerCoreService.registerCapabilityTools(tools)` — additive public seam
  to register host-supplied in-process capability tools (e.g. a desktop `io.*`
  process/device tool-pack) after boot. The core depends on no capability
  package, so platform-specific adapters (`dart:io` process execution, etc.)
  stay in the host layer; the tools share the same in-process dispatcher as the
  standard `bk.*` / `mcp.*` surface. Safe to call more than once.

## 0.1.8 - 2026-06-10 - Extension transport connection seam (additive)

### Added
- `AppPlayerCoreService.connectExtensionTransport({id, transport})` — new
  public method that lets a host app connect to an external MCP server over a
  host-supplied extension transport (serial / usb / ble / tcp / ws) without
  adding the transport's FFI / platform dependencies to `appplayer_core`. The
  transport is built by the calling app (e.g. using classes exported from
  `mcp_bridge`) and injected here; the core routes it through
  `McpClientKernelHost.connectWith` (brain_kernel 0.1.2). Returns a
  `KernelClientConnection` whose `callTool` / `readResource` / `listTools`
  reach the remote server. Throws `StateError` when the kernel is not booted.

### Changed (dependency floor)
- `brain_kernel` `^0.1.1` → `^0.1.2` — `connectExtensionTransport` delegates
  to `McpClientKernelHost.connectWith` and re-exports `clientTools`, both new
  in brain_kernel 0.1.2. The floor guarantees these symbols are present.

### Backward compatibility
- Fully additive. No existing `AppPlayerCoreService` method or constructor
  changed. Apps that do not use extension transports see no behavior change.

### Tests
- 302/302 (301 + 1 skipped) PASS. `analyze` 0 issues.

---

## 0.1.7 - 2026-06-01 - brain_kernel KernelApp + bundle session bridge integration + MCP serving

- **BrainBridge removed** (phase D · 2026-05-24) — 451 lines + 6 facade wrappers + 2 tests dropped. `AppPlayerCoreService` now calls `KernelApp.boot(...)` directly, registers `standardTools(app)`, and delegates `setActiveBundle` / `scopeIdFor`. Zero external-shell cascade.
- **bundle session bridge wiring** (2026-05-25) — `BundleSessionBridge` lifecycle wired at 5 points of `AppPlayerCoreService` (boot / activate / onClose / closeApp / dispose). `_sessions` is a per-bundleId map. `McpAtom` + `AgentAtom` gain optional `bridge` / `session` arguments and wrap dispatch in `bridge.runScoped(session, ...)`.
- **MCP serving** (MCP Serving 1.0) — `_activateBundleSections` exposes the active bundle at the well-known `bundle://manifest.json` resource (shared by the local-bundle and served-bundle paths). `openAppFromServer` reconstructs a served bundle: it detects the document, parses it with `McpBundleLoader.fromJson`, and runs the same kernel activation a local bundle uses (knowledge / settings / behavior come live); tool execution stays remote and the UI loads via `ui://app`. New `servedResources` / `readServedResource` accessors. `ApplicationLoader.load` gains an optional `resources` parameter so the server is listed only once.
- **import unification** — the bridge ships inside the kernel (`brain_kernel/lib/src/system/bridge/`), so hosts import only `package:brain_kernel/brain_kernel.dart`.
- **analyze cleanup** — removed 5 `unnecessary_import` hints across `test/src/dashboard/dashboard_bundle_test.dart` + `test/src/session/app_session_impl_test.dart` (info → 0).

### Changed (dependency floor)
- `brain_kernel` `^0.1.0` → `^0.1.1` — the served-bundle path relies on brain_kernel 0.1.1 (bundle behavior activation + the MCP serving surface). This transitively raises `mcp_bundle` to `0.4.1`; appplayer_core references no 0.4.1-only symbol directly, so its own `mcp_bundle` floor stays `^0.4.0`.

### Tests
- 301 + 1 skipped PASS · analyze 0 issues.

## [0.1.6] - 2026-05-04 - flutter_mcp_ui 0.4.0 / 0.5.0 + mcp_bundle 0.3.1 alignment

- Bumps `flutter_mcp_ui_core` to `^0.4.0` and `flutter_mcp_ui_runtime` to `^0.5.0` for the spec 1.3.3 alignment cycle.
- Bumps `mcp_bundle` to `^0.3.1` (cascade: EthosRecord JSON round-trip, `BundleFolder.agents` reserved, `AgentsSection` / `PhilosophySection` models, `EthosStorePort` extensions).

## [0.1.5] - 2026-05-03 - flutter_mcp_ui 0.3.2 / 0.4.4 alignment

### Changed
- Bump `flutter_mcp_ui_core` to `^0.3.2` and `flutter_mcp_ui_runtime` to `^0.4.4` for the M3 token shorthand consumption layer (`text.variant`, `box.padding`, `card.shape/elevation`, `button.elevation`, `icon.size/sizeToken`), `FormFactorScope` token tracking, opt-in per-form-factor property override, and `box` flat-form constraint properties.

## [0.1.4] - 2026-05-02 - Field-report logging stack — corrects 0.1.3 wiring

Supersedes the misaligned 0.1.3 release. The logging primitives shipped in 0.1.3 conflated AppPlayer Core's own diagnostic logger with the MCP `notifications/message` log channel; this release re-architects them so a single in-app `LogBuffer` collects both sources, distinguished by `LogEntry.source`, and the MCP logging spec (`notifications/message` + `logging/setLevel`) is wired to its own routing path.

### Changed (breaking — 0.1.3 → 0.1.4)
- `LogEntry` now requires a `source: LogSource` (enum `core` / `mcp`). `level` field is now `McpLogLevel` (RFC 5424 8 levels — verbatim) instead of the 4-level `LogLevel`. Construct via `LogEntry.fromCore(LogLevel)` (4→8 mapping) or `LogEntry.fromMcp({serverId, params})`.
- `LogBuffer.atLeast` parameter changed from `LogLevel` to `McpLogLevel`. Added `withSource(LogSource)` filter.

### Added
- `BufferLogger` — `Logger` adapter that pushes records into a `LogBuffer` as `source=core` entries. Pair with a console adapter inside `CompositeLogger` so a single Core diagnostic call lands in DevTools (development) AND the in-app `LogBuffer` (field report).
- MCP logging spec wiring (MOD-RUNTIME-005a, NFR-OBS-006~007):
  - `NotificationRouter` routes `notifications/message` into a host-provided `McpLogMessageHandler` callback `(serverId, params)`.
  - `AppPlayerCoreService.initialize(... onMcpLogMessage: ...)` parameter.
  - `AppPlayerCoreService.setMcpLoggingLevel(serverId, McpLogLevel)` — sends `logging/setLevel` so the server filters its own emission (server-side filter, spec-canonical).
  - `McpLogMessageHandler` typedef and `McpLogLevel` (re-export from `mcp_client`) in the public barrel.

### Rationale
Two log layers, one destination:
- **Development** uses OS standard log pipelines (host `ConsoleLogger` → `dart:developer.log` → DevTools / Console.app / logcat). Core diagnostics also flow there via `CompositeLogger`.
- **Field reports** require an in-app surface that production users can export when filing an issue. `BufferLogger` (Core diagnostics) and `onMcpLogMessage` (server logs) both feed the same `LogBuffer`, distinguished by `LogEntry.source`.

---

## [0.1.3] - 2026-05-02 - Logging primitives (LogEntry / LogBuffer / ScopedLogger)

### Added
- `LogEntry` — structured record (timestamp, level, message, context, error, stackTrace).
- `LogBuffer` — `ChangeNotifier` ring buffer (default 1000 entries) with scope/level filters. Tier shells (Pro / X / Custom) read this buffer to render in-app log viewers.
- `ScopedLogger` — `Logger` decorator that injects a fixed scope map (e.g. `{serverId, handle}`) into every log call's context, so downstream filters can isolate logs per connection/app.
- `CompositeLogger` — fan-out to multiple inner loggers (typical use: console adapter + LogBuffer adapter side-by-side).

Core internal modules (ConnectionManager / ToolDispatcher / AppSession / NotificationRouter / ResourceSubscriber) are unchanged — composition roots inject a `ScopedLogger` and the existing `_logger.debug(...)` calls automatically carry the scope.

> **Note:** This release misaligned the LogBuffer wiring with the MCP logging spec — see 0.1.4 for the corrected design (LogEntry.source, LogEntry.fromMcp, NotificationRouter `notifications/message` handler, `setMcpLoggingLevel` API).

---

## [0.1.2] - 2026-05-01 - Tool dispatcher align with runtime 0.4.3

### Changed
- `ToolDispatcher.call` now returns `Future<dynamic>` (the decoded JSON response) instead of `Future<void>`. Host self-fold removed; the runtime applies auto-merge against its own state.
- `runtime` parameter dropped from `ToolDispatcher.call` — no longer needed.
- `AppSessionImpl._onToolCall` returns the dispatcher's response so the runtime can fold it.
- Runtime dependency raised to `flutter_mcp_ui_runtime: ^0.4.3` (carries auto-merge + `event` variable + errorBoundary/errorRecovery `event.{error, stack}` fixes).

---

## [0.1.1] - 2026-04-30 - mcp_client 2.0 dependency

### Changed
- Upgraded `mcp_client` constraint to `^2.0.0`. Public API of appplayer_core is unchanged — mcp_client is consumed internally and not re-exported.

---

## [0.1.0] - 2026-04-28 - Initial Release

### Added
- `AppPlayerCoreService` orchestrator owning connection lifecycle, sessions, bundle install pipeline, and tool dispatch.
- Session abstractions — `AppSession`, `DashboardSession`, `AppHandle`.
- Connection observability — `ConnectionInfo`, `ConnectionResult`, `ConnectionState`, `ConnectionHealthMonitor` with `HealthMonitorConfig`.
- Bundle handles and host ports — `BundleRef`, `BundleEntryPoint`, `BundleFetcher`, `InstalledAppBundle`.
- Dashboard bundle composition — `DashboardBundleRef`, `BundleSource`, `SlotDefinition`, `SlotBindingRule`.
- Apps registry — `AppsRegistry` + `RegistryMetadataSink` automatic metadata refresh.
- Tenant model — `TenantContext`, `TenantSource` for multi-tenant variants.
- Host ports — `ServerStorage`, `CredentialVault`, `AppMetadataSink`.
- Observability ports — `Logger`, `MetricsPort`.
- Re-exports from `flutter_mcp_ui_runtime` — `FormFactor`, `FormFactorScope`, `ViewMode`/`ViewModeResolver`, `AppSpacing` / `AppIconSizes` / `AppTypography` / `AppDensity` (and their scale companions), `TrustLevel`, `TrustLevelManager`.
- Re-export of `MCPUIDSLVersion` from `flutter_mcp_ui_core`.
- Active-state extension via `app_activity.dart`.
