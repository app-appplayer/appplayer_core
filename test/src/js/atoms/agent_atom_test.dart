import 'package:appplayer_core/internals.dart';
import 'package:brain_kernel/brain_kernel.dart' as bk;
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AgentAtom', () {
    late bk.KernelApp app;
    late AgentAtom atom;

    setUp(() async {
      app = await bk.KernelApp.boot(
        workspaceId: 'test',
        kvStorage: bk.InMemoryKvStoragePort(),
      );
      atom = AgentAtom(app);
    });

    tearDown(() async {
      await app.shutdown();
    });

    test('key + verb names', () {
      expect(atom.key, 'agent');
      expect(
        atom.verbs.map((v) => v.name).toList(),
        ['invoke', 'list'],
      );
    });

    test('list returns ids of created agents', () async {
      await app.system.agents.createAgent(
        id: 'sara',
        displayName: 'Sara',
        role: bk.AgentRole.worker,
        model: bk.ModelSpec.stub(),
        workspaceId: 'test',
      );
      final ids = await atom.dispatch('list', const []) as List;
      expect(ids, contains('sara'));
    });

    test('invoke calls agents.ask and returns content', () async {
      await app.system.agents.createAgent(
        id: 'sara',
        displayName: 'Sara',
        role: bk.AgentRole.worker,
        model: bk.ModelSpec.stub(),
        workspaceId: 'test',
        systemPrompt: 'helpful',
      );
      final out = await atom.dispatch('invoke', ['sara', 'hello']) as Map;
      expect(out['agentId'], 'sara');
      expect(out['content'], isA<String>());
    });

    test('invoke with no args throws ArgumentError', () async {
      expect(
        () => atom.dispatch('invoke', const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invoke with non-String agentId throws ArgumentError', () async {
      expect(
        () => atom.dispatch('invoke', [42, 'msg']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invoke with empty agentId throws ArgumentError', () async {
      expect(
        () => atom.dispatch('invoke', ['', 'msg']),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('invoke with non-String message throws ArgumentError', () async {
      expect(
        () => atom.dispatch('invoke', ['sara', 42]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('unknown verb throws ArgumentError', () async {
      expect(
        () => atom.dispatch('nope', const []),
        throwsA(isA<ArgumentError>()),
      );
    });

    // The "unbooted" path retired with `BrainBridge` — `KernelApp` is
    // only constructible via `boot()`, so there is no observable
    // unbooted state to assert on. The KernelApp regression covers
    // boot / shutdown lifecycle on its own.
  });
}
