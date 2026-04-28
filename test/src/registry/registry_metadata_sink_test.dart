import 'package:appplayer_core/appplayer_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

class _Entry {
  _Entry({required this.id, this.iconUrl, this.metaName});
  final String id;
  final String? iconUrl;
  final String? metaName;
  _Entry copyWith({String? iconUrl, String? metaName}) =>
      _Entry(id: id, iconUrl: iconUrl ?? this.iconUrl, metaName: metaName ?? this.metaName);
}

class _InMemoryRegistry extends ValueNotifier<List<_Entry>>
    implements AppsRegistry<_Entry> {
  _InMemoryRegistry(super.initial);

  @override
  _Entry? byId(String appId) {
    for (final e in value) {
      if (e.id == appId) return e;
    }
    return null;
  }

  @override
  Future<void> add(_Entry app) async {
    final next = List<_Entry>.from(value);
    final i = next.indexWhere((e) => e.id == app.id);
    if (i >= 0) {
      next[i] = app;
    } else {
      next.add(app);
    }
    value = List.unmodifiable(next);
  }

  @override
  Future<void> update(_Entry app) async {
    final next = List<_Entry>.from(value);
    final i = next.indexWhere((e) => e.id == app.id);
    if (i < 0) return;
    next[i] = app;
    value = List.unmodifiable(next);
  }

  @override
  Future<void> remove(String appId) async {
    final next = value.where((e) => e.id != appId).toList();
    if (next.length == value.length) return;
    value = List.unmodifiable(next);
  }
}

void main() {
  group('RegistryMetadataSink', () {
    test('updates the matching entry via merge callback', () async {
      final registry = _InMemoryRegistry([_Entry(id: 'srv-1')]);
      final sink = RegistryMetadataSink<_Entry>(
        registry: registry,
        merge: (e, m) => e.copyWith(iconUrl: m.iconUri, metaName: m.name),
      );

      await sink.onMetadata(const AppMetadata(
        appId: 'srv-1',
        sourceKind: 'online',
        name: 'Test App',
        version: '1.0.0',
        iconUri: 'https://example.com/icon.png',
      ));

      final entry = registry.byId('srv-1');
      expect(entry, isNotNull);
      expect(entry!.iconUrl, 'https://example.com/icon.png');
      expect(entry.metaName, 'Test App');
    });

    test('no-op when appId does not match any registered entry', () async {
      final registry = _InMemoryRegistry([_Entry(id: 'srv-1')]);
      final sink = RegistryMetadataSink<_Entry>(
        registry: registry,
        merge: (e, m) => e.copyWith(iconUrl: m.iconUri),
      );

      await sink.onMetadata(const AppMetadata(
        appId: 'srv-unknown',
        sourceKind: 'online',
        name: 'X',
        version: '1.0.0',
      ));

      expect(registry.byId('srv-1')!.iconUrl, isNull);
    });

    test('skips registry update when merge returns identical instance',
        () async {
      final registry = _InMemoryRegistry([_Entry(id: 'srv-1')]);
      final calls = <List<_Entry>>[];
      registry.addListener(() => calls.add(registry.value));

      final sink = RegistryMetadataSink<_Entry>(
        registry: registry,
        merge: (e, m) => e, // identity — no real change
      );

      await sink.onMetadata(const AppMetadata(
        appId: 'srv-1',
        sourceKind: 'online',
        name: 'Test',
        version: '1.0.0',
      ));

      expect(calls, isEmpty);
    });

    test('listener fires after metadata-driven update', () async {
      final registry = _InMemoryRegistry([_Entry(id: 'srv-1')]);
      var notifications = 0;
      registry.addListener(() => notifications++);

      final sink = RegistryMetadataSink<_Entry>(
        registry: registry,
        merge: (e, m) => e.copyWith(iconUrl: m.iconUri),
      );

      await sink.onMetadata(const AppMetadata(
        appId: 'srv-1',
        sourceKind: 'online',
        name: 'X',
        version: '1.0.0',
        iconUri: 'https://x.example.com/icon.png',
      ));

      expect(notifications, 1);
    });
  });

  group('ChainedAppMetadataSink', () {
    test('forwards metadata to every sink in declaration order', () async {
      final calls = <String>[];
      final chain = ChainedAppMetadataSink([
        _RecordingSink('a', calls),
        _RecordingSink('b', calls),
        _RecordingSink('c', calls),
      ]);

      await chain.onMetadata(const AppMetadata(
        appId: 'srv-1',
        sourceKind: 'online',
        name: 'X',
        version: '1.0.0',
      ));

      expect(calls, ['a', 'b', 'c']);
    });

    test('continues after a sink throws', () async {
      final calls = <String>[];
      final chain = ChainedAppMetadataSink([
        _ThrowingSink(),
        _RecordingSink('b', calls),
      ]);

      await chain.onMetadata(const AppMetadata(
        appId: 'srv-1',
        sourceKind: 'online',
        name: 'X',
        version: '1.0.0',
      ));

      expect(calls, ['b']);
    });
  });
}

class _RecordingSink implements AppMetadataSink {
  _RecordingSink(this.label, this.log);
  final String label;
  final List<String> log;

  @override
  Future<void> onMetadata(AppMetadata metadata) async {
    log.add(label);
  }
}

class _ThrowingSink implements AppMetadataSink {
  @override
  Future<void> onMetadata(AppMetadata metadata) async {
    throw StateError('boom');
  }
}
