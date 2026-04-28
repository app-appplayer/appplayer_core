import '../exceptions.dart';
import '../logging/logger.dart';
import 'dashboard_bundle.dart';

/// Matches [SlotDefinition]s to concrete device IDs using their binding rules
/// (MOD-DASH-003, FR-DASH-004).
class SlotBinder {
  SlotBinder({Logger? logger}) : _logger = logger ?? NoopLogger();

  final Logger _logger;

  List<SlotBinding> bind({
    required List<SlotDefinition> slots,
    required List<String> deviceIds,
    Map<String, Map<String, dynamic>> deviceMetadata = const {},
  }) {
    final result = <SlotBinding>[];
    final used = <String>{};

    for (final slot in slots) {
      final deviceId = _match(
        slot.binding,
        deviceIds,
        deviceMetadata,
        used,
      );
      if (deviceId == null) {
        throw SlotBindingException(slot.slotId, 'No matching device');
      }
      _logger.debug('Bound slot',
          {'slotId': slot.slotId, 'deviceId': deviceId});
      result.add(SlotBinding(slotId: slot.slotId, deviceId: deviceId));
      used.add(deviceId);
    }

    return result;
  }

  String? _match(
    SlotBindingRule rule,
    List<String> deviceIds,
    Map<String, Map<String, dynamic>> metadata,
    Set<String> used,
  ) {
    switch (rule) {
      case ExplicitBinding(deviceId: final id):
        return deviceIds.contains(id) ? id : null;

      case TagBinding(tag: final tag):
        for (final id in deviceIds) {
          if (used.contains(id)) continue;
          final tags = metadata[id]?['tags'];
          if (tags is List && tags.contains(tag)) return id;
        }
        return null;

      case FilterBinding(filter: final filter):
        for (final id in deviceIds) {
          if (used.contains(id)) continue;
          if (_matchFilter(metadata[id], filter)) return id;
        }
        return null;
    }
  }

  bool _matchFilter(
    Map<String, dynamic>? meta,
    Map<String, dynamic> filter,
  ) {
    if (meta == null) return false;
    for (final entry in filter.entries) {
      if (meta[entry.key] != entry.value) return false;
    }
    return true;
  }
}
