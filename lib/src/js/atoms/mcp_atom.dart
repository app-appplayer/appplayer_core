/// `host.mcp.*` atom — cross-tool dispatch. A JS call
/// `host.mcp.callTool(name, args)` is forwarded to AppPlayer Core's
/// `ToolDispatcher.callInProcess`, which then invokes the registered
/// standard tool surface (the brain_kernel `bk.*` facades, or any
/// other in-process JS tool).
///
/// Bundles must declare `"mcp"` in `requires.builtinAtoms` to access
/// this atom — the host gates the namespace at attach time via
/// `allowedAtoms`.
library;

import 'package:brain_kernel/brain_kernel.dart'
    show BundleSessionBridge, DispatchSession;

import '../../runtime/tool_dispatcher.dart';
import '../atom_category.dart';

class McpAtom extends AtomCategory {
  McpAtom(this._dispatcher, {this.bridge, this.session});

  final ToolDispatcher _dispatcher;

  /// Optional bridge. When present (with a non-null [session]) every
  /// `callTool` dispatches inside `bridge.runScoped(session, ...)`,
  /// so the in-process handler's `DispatchContext.scopeId` lookups
  /// auto-prefix local ids with the active session's bundleId.
  /// Pre-bridge AppPlayer hosts (or tests) leave both null and
  /// dispatch falls back to direct `callInProcess`.
  final BundleSessionBridge? bridge;
  final DispatchSession? session;

  @override
  String get key => 'mcp';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb(
          'callTool',
          description:
              'Invoke a registered host MCP tool. (toolName, args) → '
              '{isError, body}.',
        ),
        AtomVerb(
          'listTools',
          description: 'List registered host MCP tool ids.',
        ),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'callTool':
        if (args.isEmpty) {
          throw ArgumentError('callTool requires (toolName, [args])');
        }
        final toolName = args[0];
        if (toolName is! String || toolName.isEmpty) {
          throw ArgumentError('toolName must be a non-empty String');
        }
        final toolArgs =
            args.length > 1 ? args[1] : const <String, dynamic>{};
        if (toolArgs is! Map) {
          throw ArgumentError('args must be an object map');
        }
        final params = Map<String, dynamic>.from(toolArgs);
        try {
          final b = bridge;
          final s = session;
          final result = (b != null && s != null)
              ? await b.runScoped(s,
                  () => _dispatcher.callInProcess(toolName, params))
              : await _dispatcher.callInProcess(toolName, params);
          // The in-process result is already a decoded Map / List /
          // primitive (the shape returned by `ToolDispatcher.callInProcess`).
          // Wrap it in the JS-side `{isError, body}` envelope contract.
          return <String, dynamic>{
            'isError': false,
            'body': result,
          };
        } catch (e) {
          return <String, dynamic>{
            'isError': true,
            'body': <String, dynamic>{'error': e.toString()},
          };
        }
      case 'listTools':
        return _dispatcher.inProcessToolNames;
      default:
        throw ArgumentError('unknown verb: mcp.$verb');
    }
  }
}
