/// MOD-LIC-001 — the way into an app's open-source notices (FR-LIC-001~004).
///
/// What an app ships differs by app: one carries a Rust library and a WebRTC
/// SDK, another carries neither. So the list is the app's, generated from its
/// own lock files, and this module only registers what the app hands it and
/// opens the page that shows everything registered.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

abstract final class OpenSourceLicenses {
  static final Set<String> _registered = {};

  /// Registers the notices the app keeps at [assetKey] — the native
  /// dependencies Flutter does not collect by itself (FR-LIC-003).
  ///
  /// A second call with the same key adds nothing. A malformed list throws
  /// rather than being skipped: a notice missing from a shipped app is the
  /// failure this exists to prevent (FR-LIC-004).
  static void registerBundled(String assetKey, {AssetBundle? bundle}) {
    if (!_registered.add(assetKey)) return;
    final source = bundle ?? rootBundle;
    LicenseRegistry.addLicense(() async* {
      final raw = await source.loadString(assetKey);
      for (final entry in parseBundled(raw, from: assetKey)) {
        yield entry;
      }
    });
  }

  /// Reads the bundled format: `[{"packages": [..], "license": "text"}]`.
  static List<LicenseEntry> parseBundled(String raw, {String from = 'licenses'}) {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      throw FormatException('$from: expected a list of notices');
    }
    return [
      for (final (i, item) in decoded.indexed) _entry(item, '$from[$i]'),
    ];
  }

  static LicenseEntry _entry(Object? item, String at) {
    if (item is! Map) throw FormatException('$at: expected an object');
    final packages = item['packages'];
    final text = item['license'];
    if (packages is! List ||
        packages.isEmpty ||
        packages.any((p) => p is! String || p.isEmpty)) {
      throw FormatException('$at: "packages" must be a non-empty list of names');
    }
    if (text is! String || text.trim().isEmpty) {
      throw FormatException('$at: "license" must be the full text');
    }
    return LicenseEntryWithLineBreaks(packages.cast<String>(), text);
  }

  /// Opens every registered notice — Flutter's collection of the Dart
  /// dependencies and whatever the app registered (FR-LIC-001).
  static void open(
    BuildContext context, {
    required String appName,
    String? version,
    Widget? icon,
  }) {
    showLicensePage(
      context: context,
      applicationName: appName,
      applicationVersion: version,
      applicationIcon: icon,
    );
  }

  @visibleForTesting
  static void resetForTest() => _registered.clear();
}
