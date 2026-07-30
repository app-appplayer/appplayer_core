/// `JsToolIsolate` — a per-bundle JavaScript engine, isolated from the app.
///
/// The isolation is the point, not an implementation detail: bundle JS must
/// not reach the host's state. Each platform gets the isolation primitive it
/// actually has — a Dart `Isolate` running an embedded engine on native, a Web
/// Worker on the web — behind one API and one JS-side contract
/// (`js_bridge_protocol.dart`).
library;

export 'js_bridge_protocol.dart' show HostAtomDispatcher, JsIsolateEvalResult;
export 'js_tool_isolate_web.dart'
    if (dart.library.io) 'js_tool_isolate_io.dart';
