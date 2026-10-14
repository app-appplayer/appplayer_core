/// `host.member` answers what the host's port says, per app (spec 24 §7.2).
library;

import 'package:appplayer_core/internals.dart';
import 'package:flutter_test/flutter_test.dart';

class _Port implements WorkspaceMemberPort {
  final List<(String, String?)> asked = [];

  @override
  Future<Map<String, Object?>?> me() async => {
        'uid': 'u1',
        'kind': 'human',
        'unit': 'cell-a',
        'units': [
          {'id': 'cell-a', 'name': 'Cell A', 'parent': null},
        ],
      };

  @override
  Future<bool> can(String right, {String? unit}) async {
    asked.add((right, unit));
    return right == 'write' && unit == 'cell-a';
  }

  @override
  Future<List<Map<String, Object?>>> people() async => [
        {'uid': 'u1', 'role': 'member', 'label': null},
      ];
}

void main() {
  late _Port port;
  late MemberAtom atom;

  setUp(() {
    port = _Port();
    atom = MemberAtom(port);
  });

  test('is host.member with me · can · people', () {
    expect(atom.key, 'member');
    expect(atom.verbs.map((v) => v.name), ['me', 'can', 'people']);
  });

  test('me and people are the port\'s answers', () async {
    expect((await atom.dispatch('me', const [])) as Map, containsPair('uid', 'u1'));
    expect(await atom.dispatch('people', const []), hasLength(1));
  });

  test('can passes the right and the unit through', () async {
    expect(
        await atom.dispatch('can', const [
          'write',
          {'unit': 'cell-a'},
        ]),
        isTrue);
    expect(await atom.dispatch('can', const ['write']), isFalse);
    expect(port.asked, [('write', 'cell-a'), ('write', null)]);
  });

  test('a call without a right, or an unknown verb, is refused', () async {
    await expectLater(atom.dispatch('can', const []), throwsArgumentError);
    await expectLater(atom.dispatch('other', const []), throwsArgumentError);
  });
}
