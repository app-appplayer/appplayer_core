/// `host.agent.*` atom — agent dispatch. A JS call
/// `host.agent.invoke(agentId, message)` is forwarded to the brain_kernel
/// `AgentFacade.ask` method through the host's [KernelApp].
///
/// Bundles must declare `"agent"` in `requires.builtinAtoms` to access
/// this atom.
library;

import 'package:brain_kernel/brain_kernel.dart' as bk;
import 'package:brain_kernel/brain_kernel.dart'
    show BundleSessionBridge, DispatchSession;

import '../atom_category.dart';

class AgentAtom extends AtomCategory {
  AgentAtom(this._app, {this.bridge, this.session});

  final bk.KernelApp _app;

  /// Optional bridge. When present (with a non-null [session]) every
  /// agent dispatch runs inside `bridge.runScoped(session, ...)` so
  /// the agent id scope follows the active bundle's namespace.
  final BundleSessionBridge? bridge;
  final DispatchSession? session;

  @override
  String get key => 'agent';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb(
          'invoke',
          description: 'Ask an agent (agentId, message) → reply text.',
        ),
        AtomVerb(
          'list',
          description: 'List registered agent ids.',
        ),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    final b = bridge;
    final s = session;
    if (b != null && s != null) {
      return b.runScoped(s, () => _dispatchInner(verb, args));
    }
    return _dispatchInner(verb, args);
  }

  Future<Object?> _dispatchInner(String verb, List<Object?> args) async {
    final system = _app.system;
    switch (verb) {
      case 'invoke':
        if (args.length < 2) {
          throw ArgumentError('invoke requires (agentId, message)');
        }
        final agentId = args[0];
        final message = args[1];
        if (agentId is! String || agentId.isEmpty) {
          throw ArgumentError('agentId must be a non-empty String');
        }
        if (message is! String) {
          throw ArgumentError('message must be a String');
        }
        final bk.AgentReply reply =
            await system.agents.ask(_app.scopeIdFor(agentId), message);
        return <String, dynamic>{
          'agentId': reply.agentId,
          'content': reply.content,
          if (reply.finishReason != null) 'finishReason': reply.finishReason,
        };
      case 'list':
        final all = await system.agents.listAgents();
        return all.map((a) => a.id).toList();
      default:
        throw ArgumentError('unknown verb: agent.$verb');
    }
  }
}
