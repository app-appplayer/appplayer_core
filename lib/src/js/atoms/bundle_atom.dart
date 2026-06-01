/// `host.bundle.*` atom — read-only access to the activation context's
/// own bundle metadata. The JS call `host.bundle.current()` returns the
/// running bundle's id / name / version / shortId / directory.
library;

import 'package:mcp_bundle/mcp_bundle.dart' as mb;

import '../atom_category.dart';

class BundleAtom extends AtomCategory {
  BundleAtom({required this.bundle});

  final mb.McpBundle bundle;

  @override
  String get key => 'bundle';

  @override
  List<AtomVerb> get verbs => const [
        AtomVerb(
          'current',
          description: 'Returns id / name / version / shortId / directory '
              'of the bundle this tool is running inside.',
        ),
      ];

  @override
  Future<Object?> dispatch(String verb, List<Object?> args) async {
    switch (verb) {
      case 'current':
        return <String, dynamic>{
          'id': bundle.manifest.id,
          'name': bundle.manifest.name,
          'shortId': _shortId(bundle.manifest.id),
          'version': bundle.manifest.version,
          'directory': bundle.directory,
        };
      default:
        throw ArgumentError('unknown verb: bundle.$verb');
    }
  }

  String _shortId(String id) {
    final dot = id.lastIndexOf('.');
    return dot >= 0 ? id.substring(dot + 1) : id;
  }
}
