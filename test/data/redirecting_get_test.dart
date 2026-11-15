import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mpvson/data/services/redirecting_get.dart';

/// A stub client that answers each request from a scripted list of responses.
class _ScriptedClient extends http.BaseClient {
  _ScriptedClient(this.responses);

  final List<http.StreamedResponse> responses;
  final List<Uri> requested = <Uri>[];

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requested.add(request.url);
    if (responses.isEmpty) {
      fail('Unexpected extra request to ${request.url}');
    }
    return responses.removeAt(0);
  }
}

http.StreamedResponse _response(
  int status, {
  String? location,
  int length = 0,
}) {
  return http.StreamedResponse(
    Stream<List<int>>.value(utf8.encode('x' * length)),
    status,
    headers: <String, String>{
      if (location != null) 'location': location,
      if (length > 0) 'content-length': '$length',
    },
  );
}

http.Request _getRequest(Uri uri) => http.Request('GET', uri);

void main() {
  group('sendGetFollowingRedirects', () {
    test(
      'returns a non-redirect response without following anything',
      () async {
        final client = _ScriptedClient([_response(200, length: 4)]);
        final cancelled = <http.StreamedResponse>[];

        final response = await sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (response) async => cancelled.add(response),
          refuse: (refusal) => StateError(refusal.name),
        );

        expect(response.statusCode, 200);
        expect(client.requested, [
          Uri.parse('https://example.test/update.json'),
        ]);
        expect(cancelled, isEmpty);
      },
    );

    test('follows a relative redirect and requests the resolved URL', () async {
      final client = _ScriptedClient([
        _response(302, location: '/v2/update.json'),
        _response(200, length: 4),
      ]);
      final cancelled = <http.StreamedResponse>[];

      final response = await sendGetFollowingRedirects(
        uri: Uri.parse('https://example.test/update.json'),
        maxRedirects: 4,
        send: (uri) => client.send(_getRequest(uri)),
        cancelBody: (response) async => cancelled.add(response),
        refuse: (refusal) => StateError(refusal.name),
      );

      expect(response.statusCode, 200);
      expect(client.requested, [
        Uri.parse('https://example.test/update.json'),
        Uri.parse('https://example.test/v2/update.json'),
      ]);
      expect(cancelled, hasLength(1));
    });

    test('refuses a redirect to a non-HTTPS host', () async {
      final client = _ScriptedClient([
        _response(302, location: 'http://evil.test/update.json'),
      ]);
      final refusals = <RedirectRefusal>[];

      await expectLater(
        sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) {
            refusals.add(refusal);
            return StateError(refusal.name);
          },
        ),
        throwsStateError,
      );

      expect(refusals, [RedirectRefusal.insecureTarget]);
    });

    test('refuses a redirect that carries credentials', () async {
      final client = _ScriptedClient([
        _response(302, location: 'https://user:pw@example.test/update.json'),
      ]);

      await expectLater(
        sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) => StateError(refusal.name),
        ),
        throwsStateError,
      );
    });

    test('refuses a redirect with no Location header', () async {
      final client = _ScriptedClient([_response(302)]);
      final refusals = <RedirectRefusal>[];

      await expectLater(
        sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) {
            refusals.add(refusal);
            return StateError(refusal.name);
          },
        ),
        throwsStateError,
      );

      expect(refusals, [RedirectRefusal.missingLocation]);
    });

    test('stops at the redirect cap and reports it', () async {
      // One more redirect response than the cap allows.
      final client = _ScriptedClient([
        for (var i = 0; i < 6; i++) _response(302, location: '/hop-$i'),
      ]);
      final refusals = <RedirectRefusal>[];

      await expectLater(
        sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) {
            refusals.add(refusal);
            return StateError(refusal.name);
          },
        ),
        throwsStateError,
      );

      expect(refusals, [RedirectRefusal.tooManyRedirects]);
      expect(client.requested, hasLength(5));
    });

    test(
      'returns the final response after the last allowed redirect',
      () async {
        final client = _ScriptedClient([
          for (var i = 0; i < 4; i++) _response(302, location: '/hop-$i'),
          _response(200, length: 4),
        ]);

        final response = await sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) => StateError(refusal.name),
        );

        expect(response.statusCode, 200);
        expect(client.requested, hasLength(5));
      },
    );

    test(
      'returns error responses to the caller instead of following',
      () async {
        final client = _ScriptedClient([_response(404)]);

        final response = await sendGetFollowingRedirects(
          uri: Uri.parse('https://example.test/update.json'),
          maxRedirects: 4,
          send: (uri) => client.send(_getRequest(uri)),
          cancelBody: (_) async {},
          refuse: (refusal) => StateError(refusal.name),
        );

        expect(response.statusCode, 404);
        expect(client.requested, hasLength(1));
      },
    );
  });
}
