/// Credentials for a served address, answered by the host.
///
/// Some served documents act for a person: their server answers a call that
/// needs one with HTTP 401 and a `WWW-Authenticate` challenge. Who that person
/// is, and how they sign in, is the host's — core only asks before each
/// request and, after a 401, asks whether to try once more.
library;

import 'package:http/http.dart' as http;

/// What the host answers about credentials for served addresses.
abstract class ServingAuthorization {
  /// The `Authorization` header value to send to [endpoint], or null for none.
  ///
  /// Asked before every request on a served connection. Answering for an
  /// address the host does not recognise is how a credential leaks; return
  /// null for anything that is not yours.
  Future<String?> authorizationFor(Uri endpoint);

  /// Called after [endpoint] refused a call with 401. Returns the header to
  /// retry once with, or null to let the refusal stand. [wwwAuthenticate] is
  /// the challenge the server sent, when it sent one.
  Future<String?> afterUnauthorized(Uri endpoint, {String? wwwAuthenticate});
}

/// Other headers the host sends to a served address — not credentials (an
/// anonymous per-install visitor id that lets a server tell two people on one
/// network apart). Asked before every request on a served connection; return
/// nothing for an address that is not the host's own.
abstract class ServingHeaders {
  Future<Map<String, String>> headersFor(Uri endpoint);
}

/// An HTTP client that remembers the last `WWW-Authenticate` challenge a 401
/// carried.
///
/// The protocol client reports a 401 as an error code and drops the header; the
/// host needs the challenge to tell whose sign-in was asked for.
class ChallengeRecordingClient extends http.BaseClient {
  ChallengeRecordingClient([http.Client? inner])
      : _inner = inner ?? http.Client();

  final http.Client _inner;

  /// The challenge of the most recent 401, or null when there was none since
  /// the last [takeChallenge].
  String? _lastChallenge;

  /// Returns the recorded challenge and forgets it, so one refusal is answered
  /// once.
  String? takeChallenge() {
    final challenge = _lastChallenge;
    _lastChallenge = null;
    return challenge;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _inner.send(request);
    if (response.statusCode == 401) {
      _lastChallenge = response.headers['www-authenticate'];
    }
    return response;
  }

  @override
  void close() => _inner.close();
}
