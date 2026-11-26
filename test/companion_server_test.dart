import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ilonatv/app.dart' show kVersion;
import 'package:ilonatv/companion/pairing.dart';
import 'package:ilonatv/companion/server.dart';
import 'package:ilonatv/companion/state.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeApi implements CompanionApi {
  final calls = <(String, String, Map<String, String>, Object?)>[];
  bool fail = false;
  (int, Object) answer = (404, {'error': 'notFound'});

  @override
  Future<(int, Object)> handle(
    String method,
    String path,
    Map<String, String> query,
    Object? body,
  ) async {
    calls.add((method, path, query, body));
    if (fail) throw StateError('boom');
    return answer;
  }
}

// Revokes a token right after its first passing check, with no notification,
// as if Remove ran while the WebSocket upgrade was in flight.
class RevokingPairing extends Pairing {
  RevokingPairing(super.settings);

  String? revoke;

  @override
  bool isValid(String token) {
    final ok = super.isValid(token);
    if (ok && token == revoke) settings.companionDevices.remove(token);
    return ok;
  }
}

void main() {
  late Settings settings;
  late RevokingPairing pairing;
  late FakeApi api;
  late CompanionServer server;
  final client = HttpClient();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    companionState.setStep(null);
    settings = await Settings.load();
    pairing = RevokingPairing(settings);
    api = FakeApi();
    server = CompanionServer(
      pairing,
      api,
      port: 0,
      address: InternetAddress.loopbackIPv4,
    );
    await server.start();
  });

  tearDown(() => server.stop());
  tearDownAll(() => client.close(force: true));

  Uri url(String path) =>
      Uri.parse('http://127.0.0.1:${server.boundPort}$path');

  Future<(int, String, HttpHeaders)> send(
    String method,
    String path, {
    String? token,
    String? body,
  }) async {
    final req = await client.openUrl(method, url(path));
    if (token != null) req.headers.set('authorization', 'Bearer $token');
    if (body != null) {
      final bytes = utf8.encode(body);
      req.contentLength = bytes.length;
      req.add(bytes);
    }
    final res = await req.close();
    return (res.statusCode, await utf8.decodeStream(res), res.headers);
  }

  Future<String> pairWithSecret() async {
    final (status, body, _) = await send(
      'POST',
      '/api/pair',
      body: jsonEncode({'secret': settings.companionSecret, 'name': 'Mac'}),
    );
    expect(status, 200);
    return jsonDecode(body)['token'] as String;
  }

  Future<(WebSocket, StreamIterator<dynamic>)> events(String token) async {
    final ws = await WebSocket.connect(
      'ws://127.0.0.1:${server.boundPort}/api/events?token=$token',
    );
    return (ws, StreamIterator(ws));
  }

  Future<TvEvent> next(StreamIterator<dynamic> it) async {
    expect(await it.moveNext().timeout(const Duration(seconds: 5)), isTrue);
    return TvEvent.decode(it.current as String);
  }

  test('GET / is a page', () async {
    final (status, body, headers) = await send('GET', '/');
    expect(status, 200);
    expect(headers.contentType?.mimeType, 'text/html');
    expect(body, contains('IlonaTv is running'));
  });

  test('GET /api/info without a token is 401', () async {
    expect((await send('GET', '/api/info')).$1, 401);
    expect((await send('GET', '/api/info', token: 'nope')).$1, 401);
    expect((await send('GET', '/api/other')).$1, 401);
    expect(api.calls, isEmpty);
  });

  test(
    'pairing with the secret gives a token that works on /api/info',
    () async {
      final token = await pairWithSecret();
      final (status, body, headers) = await send(
        'GET',
        '/api/info',
        token: token,
      );
      expect(status, 200);
      expect(headers.contentType.toString(), 'application/json; charset=utf-8');
      expect(jsonDecode(body), {
        'protocol': 1,
        'version': kVersion,
        'step': null,
        'inFront': true,
        'launcherMode': false,
      });
    },
  );

  test('a code pairs only while offered', () async {
    final req = jsonEncode({'code': pairing.code, 'name': 'Phone'});
    expect((await send('POST', '/api/pair', body: req)).$1, 403);
    pairing.offerCode();
    expect((await send('POST', '/api/pair', body: req)).$1, 200);
  });

  test('a wrong code is 403 and never 500', () async {
    pairing.offerCode();
    final bad = pairing.code == '000000' ? '000001' : '000000';
    for (var i = 0; i < 8; i++) {
      final (status, body, _) = await send(
        'POST',
        '/api/pair',
        body: jsonEncode({'code': bad, 'name': 'X'}),
      );
      expect(status, 403);
      expect(jsonDecode(body), {'error': 'badPairing'});
    }
  });

  test('a malformed pair body is 400', () async {
    for (final body in [
      null,
      'not json',
      '[]',
      '{"name":"X"}',
      jsonEncode({'code': '1', 'name': ''}),
      jsonEncode({'code': '1', 'name': 'x' * 61}),
    ]) {
      expect(
        (await send('POST', '/api/pair', body: body)).$1,
        400,
        reason: body,
      );
    }
  });

  test('a 70 KB body is 413', () async {
    final big = jsonEncode({'name': 'x' * 70 * 1024});
    expect((await send('POST', '/api/pair', body: big)).$1, 413);
    final token = await pairWithSecret();
    expect((await send('POST', '/api/x', token: token, body: big)).$1, 413);
    final chunked = await client.postUrl(url('/api/x'));
    chunked.headers.set('authorization', 'Bearer $token');
    chunked.write(big);
    expect((await chunked.close()).statusCode, 413);
    expect(api.calls, isEmpty);
  });

  test('events: state at once and on change', () async {
    final token = await pairWithSecret();
    final (ws, it) = await events(token);
    final first = await next(it);
    expect(first.type, 'state');
    expect(first.data['step'], isNull);
    expect(first.data['launcherMode'], isFalse);
    companionState.setStep(SetupStep.tmdb);
    final second = await next(it);
    expect(second.type, 'state');
    expect(second.data['step'], 'tmdb');
    await ws.close();
  });

  test('events: a token revoked during the upgrade gets bye', () async {
    final token = await pairWithSecret();
    pairing.revoke = token;
    final (ws, it) = await events(token);
    expect((await next(it)).type, 'bye');
    expect(await it.moveNext().timeout(const Duration(seconds: 5)), isFalse);
    expect(ws.closeCode, WebSocketStatus.policyViolation);
  });

  test('only the bearer header opens /api/info', () async {
    final token = await pairWithSecret();
    for (final (method, path) in [
      ('GET', '/api/info?token=$token'),
      ('HEAD', '/api/info'),
      ('OPTIONS', '/api/info'),
      ('GET', '/api/info/'),
    ]) {
      expect((await send(method, path)).$1, 401, reason: '$method $path');
    }
    expect(api.calls, isEmpty);
  });

  test('events without a valid token are refused', () async {
    await expectLater(events('nope'), throwsA(isA<WebSocketException>()));
  });

  test('events: a removed device gets bye and the socket closes', () async {
    final token = await pairWithSecret();
    final (ws, it) = await events(token);
    expect((await next(it)).type, 'state');
    await pairing.remove(token);
    expect((await next(it)).type, 'bye');
    expect(await it.moveNext().timeout(const Duration(seconds: 5)), isFalse);
    expect(ws.closeCode, isNotNull);
    expect((await send('GET', '/api/info', token: token)).$1, 401);
  });

  test('unknown authed path falls to the api', () async {
    final token = await pairWithSecret();
    final (status, body, _) = await send(
      'POST',
      '/api/thing?a=1',
      token: token,
      body: '{"x":2}',
    );
    expect(status, 404);
    expect(jsonDecode(body), {'error': 'notFound'});
    expect(api.calls.single.$1, 'POST');
    expect(api.calls.single.$2, '/api/thing');
    expect(api.calls.single.$3, {'a': '1'});
    expect(api.calls.single.$4, {'x': 2});

    await send('GET', '/api/thing', token: token);
    expect(api.calls.last.$4, isNull);
  });

  test('a 204 from the api has no body', () async {
    final token = await pairWithSecret();
    api.answer = (204, const {});
    final (status, body, _) = await send('POST', '/api/key', token: token);
    expect(status, 204);
    expect(body, isEmpty);
  });

  test('a body that is not JSON is 400 before the api', () async {
    final token = await pairWithSecret();
    expect(
      (await send('POST', '/api/thing', token: token, body: '{nope')).$1,
      400,
    );
    expect(api.calls, isEmpty);
  });

  test('a failing handler is 500 and the server keeps serving', () async {
    final token = await pairWithSecret();
    api.fail = true;
    final logged = <String?>[];
    final print = debugPrint;
    debugPrint = (m, {wrapWidth}) => logged.add(m);
    addTearDown(() => debugPrint = print);
    final (status, body, _) = await send('GET', '/api/thing', token: token);
    expect(status, 500);
    expect(logged.single, contains('Bad state: boom'));
    expect(jsonDecode(body), {'error': 'internal'});
    expect((await send('GET', '/api/info', token: token)).$1, 200);
  });

  test('start is idempotent and stop frees the port', () async {
    await server.start();
    final port = server.boundPort;
    await server.stop();
    await expectLater(
      Socket.connect(
        InternetAddress.loopbackIPv4,
        port,
        timeout: const Duration(seconds: 2),
      ),
      throwsA(isA<SocketException>()),
    );
    final again = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await again.close();
  });
}
