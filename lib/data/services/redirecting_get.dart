import 'package:http/http.dart' as http;

import '../../domain/updates/update_url.dart';

/// Why a redirect chain was refused. Each updater maps these to its own
/// exception type and wording, so a shared helper does not force shared
/// user-facing messages.
enum RedirectRefusal {
  /// A 3xx response carried no usable Location header.
  missingLocation,

  /// The chain hit its cap.
  tooManyRedirects,

  /// A hop was not a credential-free, fragment-free HTTPS URL.
  insecureTarget,
}

/// Walks a GET's redirect chain under one policy: every hop must be a
/// credential-free, fragment-free HTTPS URL, and the chain is capped.
///
/// Both the app updater and the engine updater download artifacts over the
/// network, and both must refuse an `http://` redirect and an unbounded chain.
/// The callers keep their own request construction, timeouts, abort handling,
/// and status-code policy; only the hop validation and the cap live here.
///
/// [send] performs one attempt against [destination]. [cancelBody] drains and
/// discards a response the caller will not read. [refuse] raises the caller's
/// error for a given [RedirectRefusal].
Future<http.StreamedResponse> sendGetFollowingRedirects({
  required Uri uri,
  required int maxRedirects,
  required Future<http.StreamedResponse> Function(Uri destination) send,
  required Future<void> Function(http.StreamedResponse response) cancelBody,
  required Object Function(RedirectRefusal refusal) refuse,
}) async {
  var destination = uri;
  for (var redirects = 0; redirects <= maxRedirects; redirects++) {
    final response = await send(destination);
    if (response.statusCode < 300 || response.statusCode >= 400) {
      return response;
    }
    await cancelBody(response);
    final location = response.headers['location'];
    if (location == null || location.trim().isEmpty) {
      throw refuse(RedirectRefusal.missingLocation);
    }
    if (redirects == maxRedirects) {
      throw refuse(RedirectRefusal.tooManyRedirects);
    }
    destination = destination.resolve(location);
    if (!isSafeHttpsUri(destination)) {
      throw refuse(RedirectRefusal.insecureTarget);
    }
  }
  throw refuse(RedirectRefusal.tooManyRedirects);
}
