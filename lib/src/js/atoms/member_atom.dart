/// `host.member.*` atom — who is using a workspace app, and what they may do
/// (platform spec 24 §7.2).
///
/// A workspace's built-in apps show records to people by unit and by person,
/// and hide what the person cannot do. The access table that answers this is
/// the host's; the app only asks. Judging here is a convenience — the account
/// storage judges every read and write again (20 §2.9).
///
///   * `me()` → `{uid, kind, unit, units, tree}` | `null` — `units` are the
///     ones the person may act in, `tree` every unit (`{id, name, parent}`)
///   * `can(right, [{unit}])` → bool — `app:<appId>.<right>` at that unit
///   * `people()` → `[{uid, role, label}]`
library;

import '../atom_category.dart';

/// What a host tells one app about the person using it. Given per app, so
/// [can] judges that app's rights.
abstract interface class WorkspaceMemberPort {
  /// The person in the current workspace: uid, kind, the unit chosen now, the
  /// units they may choose and every unit of the workspace. Null outside a
  /// workspace with an access table.
  Future<Map<String, Object?>?> me();

  /// Whether the person holds this app's [right] at [unit] (the workspace
  /// when null).
  Future<bool> can(String right, {String? unit});

  /// The workspace's people. `label` is what this person may be shown of the
  /// other one (null when nothing).
  Future<List<Map<String, Object?>>> people();
}

/// The answer of a host with no workspace: nobody in one, no rights, no
/// people. A workspace app opened there is told it is outside one rather than
/// finding `host.member` missing.
class OutsideWorkspace implements WorkspaceMemberPort {
  const OutsideWorkspace();

  @override
  Future<Map<String, Object?>?> me() async => null;

  @override
  Future<bool> can(String right, {String? unit}) async => false;

  @override
  Future<List<Map<String, Object?>>> people() async => const [];
}

class MemberAtom extends AtomCategory {
  MemberAtom(this.port);

  final WorkspaceMemberPort port;

  @override
  String get key => 'member';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb('me',
            description: 'The person using this app. () → {uid, kind, unit, '
                'units, tree} | null.'),
        AtomVerb('can',
            description: "Whether the person holds this app's right. "
                '(right, [{unit}]) → bool.'),
        AtomVerb('people',
            description: "The workspace's people. () → [{uid, role, label}]."),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    Object? arg(int i) => i < args.length ? args[i] : null;
    switch (verb) {
      case 'me':
        return port.me();
      case 'can':
        final right = arg(0);
        if (right is! String || right.isEmpty) {
          throw ArgumentError('member.can requires (right)');
        }
        final opts = arg(1);
        final unit = opts is Map ? opts['unit'] : null;
        return port.can(right, unit: unit is String ? unit : null);
      case 'people':
        return port.people();
      default:
        throw ArgumentError('unknown verb: member.$verb');
    }
  }
}
