import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:elimor/net.dart';
import 'package:flutter_test/flutter_test.dart';

// No TestWidgetsFlutterBinding here: it replaces HttpClient with a mock that
// answers 400, and these tests talk to a real server on the loopback.
void main() {
  /// Runs [handler] for every request; the server (connections included) is
  /// closed after the test. Returns its base URI.
  Future<Uri> serve(void Function(HttpRequest req) handler) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen(handler);
    return Uri.parse('http://127.0.0.1:${server.port}');
  }

  test('getJson parses an object and wraps a list', () async {
    const bodies = {'/obj': '{"a":1}', '/list': '[1,2]', '/text': '"hi"'};
    final base = await serve((req) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(bodies[req.uri.path]);
      req.response.close();
    });

    expect(await getJson(base.resolve('/obj')), {'a': 1});
    expect(await getJson(base.resolve('/list')), {
      'items': [1, 2],
    });
    await expectLater(getJson(base.resolve('/text')), throwsFormatException);
  });

  test('non-2xx throws HttpStatusException with the body', () async {
    final base = await serve((req) {
      req.response.statusCode = HttpStatus.unauthorized;
      req.response.write('{"status_message":"bad"}');
      req.response.close();
    });

    await expectLater(
      getJson(base),
      throwsA(
        isA<HttpStatusException>()
            .having((e) => e.status, 'status', 401)
            .having((e) => e.body, 'body', contains('bad'))
            .having((e) => '$e', 'toString', contains('401')),
      ),
    );
  });

  test('postJson sends the body as JSON', () async {
    final base = await serve((req) async {
      final body = jsonDecode(await utf8.decodeStream(req));
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'method': req.method,
          'type': '${req.headers.contentType}',
          'length': req.contentLength,
          'body': body,
        }),
      );
      await req.response.close();
    });

    final sent = {'email': 'a@b', 'city': 'São Paulo'};
    // Through the typedef the sources take: a signature change that stops
    // postJson fitting Post fails here, not in a source's tests.
    final Post post = postJson;
    expect(await post(base, sent), {
      'method': 'POST',
      'type': 'application/json; charset=utf-8',
      // Announced up front, counted in UTF-8 bytes (the ã takes two).
      'length': utf8.encode(jsonEncode(sent)).length,
      'body': sent,
    });
  });

  test('a silent server times out', () async {
    final base = await serve((req) {}); // accepts, never answers
    await expectLater(
      getJson(base, timeout: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
  });

  test('getJson sends its headers and the Elimor user agent', () async {
    final base = await serve((req) {
      req.response.headers.contentType = ContentType.json;
      req.response.write(
        jsonEncode({
          'x': req.headers.value('x-test'),
          'ua': req.headers.value('user-agent'),
        }),
      );
      req.response.close();
    });

    // Through the typedef the sources take: a signature change that stops
    // getJson fitting Fetch fails here, not in a source's tests.
    final Fetch fetch = getJson;
    expect(await fetch(base, headers: {'x-test': 'yes'}), {
      'x': 'yes',
      'ua': 'Elimor/0.2',
    });
  });

  test('getBytes returns the body untouched', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0xff]);
    final base = await serve((req) {
      req.response.add(png);
      req.response.close();
    });

    expect(await getBytes(base), png);
  });

  test('getBytes returns a buffer of exactly the body size', () async {
    // Over 64 KB, so it arrives in several chunks, and a BytesBuilder's growth
    // buffer ends up well over twice the data (262144 bytes for these 100000).
    final body = Uint8List.fromList([for (var i = 0; i < 100000; i++) i % 251]);
    final base = await serve((req) {
      req.response.add(body);
      req.response.close();
    });

    final bytes = await getBytes(base);
    expect(bytes, body);
    expect(bytes.buffer.lengthInBytes, bytes.length);
  });

  test('postJson and getText send the headers they are given', () async {
    final base = await serve((req) async {
      await req.drain<void>();
      final heard =
          '${req.headers.value('user-agent')}|${req.headers.value('x-a')}';
      req.response.write(
        req.method == 'POST' ? jsonEncode({'heard': heard}) : 'ação $heard',
      );
      await req.response.close();
    });
    const headers = {'User-Agent': 'TV', 'X-A': 'b'};
    // Through the typedefs, as the sources take them.
    final Post post = postJson;
    final GetText text = getText;
    expect(await post(base, {}, headers: headers), {'heard': 'TV|b'});
    expect(await text(base, headers: headers), 'ação TV|b');
    expect(await text(base), 'ação Elimor/0.2|null');
  });

  test('postJson encodes the body before it connects', () async {
    // A port nothing listens on, so the order shows in the error: encoding
    // first throws the encoding error, opening the request first would throw a
    // SocketException (and against a live server leave a request open).
    final closed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = closed.port;
    await closed.close();

    await expectLater(
      postJson(Uri.parse('http://127.0.0.1:$port'), {'at': DateTime.now()}),
      throwsA(isA<JsonUnsupportedObjectError>()),
    );
  });
}
