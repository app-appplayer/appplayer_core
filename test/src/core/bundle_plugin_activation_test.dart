/// A bundle activated as a plugin (platform spec 29 §2): its tools enter the
/// catalog under the plugin id, nothing is mounted, and deactivating takes
/// them out again.
library;

import 'dart:io';

import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/in_memory_server_storage.dart';

class _Cap extends Logger {
  final List<String> messages = <String>[];

  @override
  void log(
    LogLevel level,
    String message, {
    Map<String, Object?>? context,
    Object? error,
    StackTrace? stackTrace,
  }) =>
      messages.add(message);
}

const _a = 'com.example.tool_scope_a';

String _fixture(String id) =>
    '${Directory.current.path}/test/fixtures/${id.split('.').last}.mbd';

Map<String, dynamic> _httpBundle({bool? destructiveHint, bool? readOnlyHint}) => {
      'schemaVersion': '1.0.0',
      'manifest': {
        'id': 'com.example.hinted',
        'name': 'Hinted',
        'version': '1.0.0',
        'schemaVersion': '1.0.0',
        'type': 'application',
      },
      'tools': {
        'schemaVersion': '1.0.0',
        'tools': [
          {
            'name': 'wipe',
            'description': 'Removes things.',
            'kind': 'mcp',
            'target': {'transport': 'http', 'url': 'http://127.0.0.1:1/mcp'},
            'inputSchema': {'type': 'object', 'properties': {}},
            if (destructiveHint != null || readOnlyHint != null)
              'annotations': {
                if (destructiveHint != null) 'destructiveHint': destructiveHint,
                if (readOnlyHint != null) 'readOnlyHint': readOnlyHint,
              },
          },
        ],
      },
    };

Map<String, dynamic> _stdioBundle(List<String> args) => {
      'schemaVersion': '1.0.0',
      'manifest': {
        'id': 'com.example.shipped_script',
        'name': 'Shipped script',
        'version': '1.0.0',
        'schemaVersion': '1.0.0',
        'type': 'application',
      },
      'tools': {
        'schemaVersion': '1.0.0',
        'tools': [
          {
            'name': 'run',
            'description': 'Runs a script.',
            'kind': 'mcp',
            'target': {
              'transport': 'stdio',
              'command': 'python3',
              'args': args,
            },
            'inputSchema': {'type': 'object', 'properties': {}},
          },
        ],
      },
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppPlayerCoreService core;

  setUp(() async {
    final tmp = await Directory.systemTemp.createTemp('appplayer-plugin-test-');
    addTearDown(() async {
      if (await tmp.exists()) await tmp.delete(recursive: true);
    });
    core = AppPlayerCoreService();
    await core.initialize(
      storage: InMemoryServerStorage(),
      bundleInstallRoot: tmp.path,
    );
    addTearDown(() async => core.dispose());
    await core.installBundleFromDirectory(_fixture(_a));
  });

  test('the tools enter the catalog under the plugin id, not the bundle id',
      () async {
    final names = await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );

    expect(names, ['board.board.summary']);
    expect(core.inProcessToolNames, contains('board.board.summary'));
    expect(core.inProcessToolNames, isNot(contains('$_a.board.summary')));
  });

  test('the tool answers when called by its catalog name', () async {
    await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );
    final answer = await core.toolDispatcherForInternals.routerFor(null)(
        'board.board.summary', <String, dynamic>{});
    expect(answer, {'from': 'a'});
  });

  test('deactivating takes the tools out of the catalog', () async {
    await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );
    await core.deactivateBundlePlugin('board');
    expect(core.inProcessToolNames, isNot(contains('board.board.summary')));
  });

  test('activating again under the same id replaces the earlier one', () async {
    await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );
    final again = await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );
    expect(again, ['board.board.summary']);
    expect(
      core.inProcessToolNames.where((n) => n == 'board.board.summary').length,
      1,
    );
  });

  test('shutting the core down deactivates what is still active', () async {
    await core.activateBundleAsPlugin(
      const BundleInstalledRef(_a),
      pluginId: 'board',
    );
    await core.dispose();
    // The tear-down runs without leaving the activation behind; a second
    // dispose (the test's own) is a no-op.
    await core.dispose();
  });

  test('deactivating an id that is not active does nothing', () async {
    await core.deactivateBundlePlugin('nothing');
  });

  test('a script the bundle ships is refused, not started with a raw token',
      () async {
    await expectLater(
      core.activateBundleAsPlugin(
        BundleInlineRef(_stdioBundle([r'${__dirname}/assets/server.py'])),
        pluginId: 'shipped',
      ),
      throwsA(isA<StateError>()),
    );
    expect(core.inProcessToolNames.any((n) => n.startsWith('shipped.')), isFalse);
  });

  test('a stdio tool with plain arguments is accepted', () async {
    final names = await core.activateBundleAsPlugin(
      BundleInlineRef(_stdioBundle(['-m', 'some_module'])),
      pluginId: 'plain',
    );
    expect(names, ['plain.run']);
  });

  group('a tool the bundle declares destructive (spec 29 §6)', () {
    Future<Object?> call(String name) => core.toolDispatcherForInternals
        .routerFor(null)(name, <String, dynamic>{});

    bool blocked(Object? r) =>
        r is Map && '${r['content']}'.contains('destructive_action_blocked');

    test('does not run without a confirmation path', () async {
      await core.activateBundleAsPlugin(
        BundleInlineRef(_httpBundle(destructiveHint: true)),
        pluginId: 'h',
      );
      expect(blocked(await call('h.wipe')), isTrue);
    });

    test('does not run when the person says no, and asks with the tool name',
        () async {
      final asked = <String>[];
      await core.activateBundleAsPlugin(
        BundleInlineRef(_httpBundle(destructiveHint: true)),
        pluginId: 'h',
        confirmDestructive: (tool, args) async {
          asked.add(tool);
          return false;
        },
      );
      expect(blocked(await call('h.wipe')), isTrue);
      expect(asked, ['h.wipe']);
    });

    test('runs when the person says yes', () async {
      await core.activateBundleAsPlugin(
        BundleInlineRef(_httpBundle(destructiveHint: true)),
        pluginId: 'h',
        confirmDestructive: (tool, args) async => true,
      );
      // Past the gate it reaches the (unreachable) server and fails there.
      Object? outcome;
      try {
        outcome = await call('h.wipe');
      } on Object catch (e) {
        outcome = e;
      }
      expect(blocked(outcome), isFalse);
    });

    test('a read-only hint or no hint lifts nothing and adds nothing', () async {
      await core.activateBundleAsPlugin(
        BundleInlineRef(_httpBundle(readOnlyHint: true)),
        pluginId: 'ro',
      );
      Object? outcome;
      try {
        outcome = await call('ro.wipe');
      } on Object catch (e) {
        outcome = e;
      }
      expect(blocked(outcome), isFalse, reason: 'not declared destructive');
    });
  });

  group('a skill the kernel refuses', () {
    Map<String, dynamic> skillBundle(String stepType) => {
          'schemaVersion': '1.0.0',
          'manifest': {
            'id': 'com.example.skilled',
            'name': 'Skilled',
            'version': '1.0.0',
            'schemaVersion': '1.0.0',
            'type': 'application',
          },
          'skills': {
            'schemaVersion': '1.0.0',
            'modules': [
              {
                'id': 'odd',
                'name': 'odd',
                'version': '1.0.0',
                'procedures': [
                  {
                    'id': 'main',
                    'name': 'main',
                    'steps': [
                      {
                        'id': 's',
                        'action': {'type': stepType},
                      },
                    ],
                  },
                ],
              },
            ],
          },
        };

    Future<_Cap> activate(String stepType) async {
      final cap = _Cap();
      final tmp = await Directory.systemTemp.createTemp('appplayer-skill-log-');
      addTearDown(() async {
        if (await tmp.exists()) await tmp.delete(recursive: true);
      });
      final c = AppPlayerCoreService();
      await c.initialize(
        storage: InMemoryServerStorage(),
        bundleInstallRoot: tmp.path,
        logger: cap,
      );
      addTearDown(() async => c.dispose());
      await c.activateBundleAsPlugin(
        BundleInlineRef(skillBundle(stepType)),
        pluginId: 'skilled',
      );
      return cap;
    }

    test('is said so in the log, not dropped silently', () async {
      final cap = await activate('bogus');
      expect(
        cap.messages.where((m) =>
            m.contains('bundle asset not activated') && m.contains('odd')),
        isNotEmpty,
      );
    });

    test('a skill it accepts logs nothing of the kind', () async {
      final cap = await activate('tool');
      expect(cap.messages.where((m) => m.contains('not activated')), isEmpty);
    });
  });
}
