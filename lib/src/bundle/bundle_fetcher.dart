import 'dart:typed_data';

/// Host-injected remote bundle fetcher (NFR-EXT-006).
///
/// The core does not implement HTTP transport. Hosts wire
/// `http` / `dio` / a platform channel as appropriate.
abstract class BundleFetcher {
  Future<Uint8List> fetch(Uri url, {Map<String, String>? headers});
}
