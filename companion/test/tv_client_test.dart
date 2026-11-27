import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';

void main() {
  late HttpServer server;
  late TvClient client;
  var inFront = true;
  var launcher = true;
  WebSocket? socket;
  late Completer<void> closed;
  var bye = true;
  var badBody = false;
  const item = {'id': 'x', 'title': 'T'};

  Future<void> reply(HttpResponse r, int s, [Object? body]) {
    r.statusCode = s;
    if (body != null) {
      r.headers.contentType = ContentType.json;
      r.write(jsonEncode(body));
    }
    return r.close();
  }

  setUp(() async {
    inFront = true;
    launcher = true;
    bye = true;
    closed = Completer();
    badBody = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      final path = req.uri.path;
      if (path == '/api/pair') {
        final b = jsonDecode(await utf8.decoder.bind(req).join()) as Map;
        return b['code'] == '123456'
            ? reply(req.response, 200, {'token': 'tok'})
            : reply(req.response, 403, {'error': 'badPairing'});
      }
      final ok = path == '/api/events'
          ? req.uri.queryParameters['token'] == 'tok'
          : req.headers.value('authorization') == 'Bearer tok';
      if (!ok) return reply(req.response, 401, {'error': 'unauthorized'});
      switch (path) {
        case '/api/events':
          socket = await WebSocketTransformer.upgrade(req);
          socket!.listen(null, onDone: closed.complete);
          socket!.add(
            const TvEvent('state', {
              'step': 'tmdb',
              'inFront': true,
              'launcherMode': false,
            }).encode(),
          );
          if (bye) socket!.add(const TvEvent('bye').encode());
        case '/api/info' when badBody:
          req.response.add([0xff, 0xfe, 0xfd]);
          return req.response.close();
        case '/api/info':
          return reply(req.response, 200, {
            'protocol': 1,
            'version': '1.2.3',
            'step': 'tmdb',
            'inFront': inFront,
            'launcherMode': launcher,
          });
        case '/api/key':
          return inFront
              ? reply(req.response, 204)
              : reply(req.response, 409, {'error': 'notInFront'});
        case '/api/open':
          return inFront
              ? reply(req.response, 200, {'opened': true})
              : reply(req.response, 409, {'error': 'notInFront'});
        case '/api/search':
          return reply(req.response, 200, {
            'movies': [item],
            'series': [item, item],
            'videos': <Object>[],
          });
        case '/api/rows':
          return reply(req.response, 200, [
            {
              'key': 'r',
              'title': 'Row',
              'items': [item],
            },
          ]);
        case '/api/setup/tmdb':
          return reply(req.response, 200, {'result': 'keyBad'});
        case '/api/setup/cities':
          return reply(req.response, 200, [
            {
              'name': 'Lisbon',
              'region': '',
              'country': 'Portugal',
              'lat': 38.7,
              'lon': -9.1,
              'countryCode': 'PT',
            },
          ]);
        case '/api/setup/city':
          return reply(req.response, 204);
        default:
          return reply(req.response, 404, {'error': 'notFound'});
      }
    });
    client = TvClient('127.0.0.1', port: server.port, token: 'tok');
  });

  tearDown(() => server.close(force: true));

  test('pair by code returns the token', () async {
    final r = await TvClient(
      '127.0.0.1',
      port: server.port,
    ).pair(code: '123456', name: 'Phone');
    expect((r as Ok<String>).value, 'tok');
  });

  test('a wrong code is Unpaired', () async {
    final r = await TvClient(
      '127.0.0.1',
      port: server.port,
    ).pair(code: '000000', name: 'Phone');
    expect(r, isA<Unpaired<String>>());
  });

  test('a bad token is Unpaired', () async {
    final r = await TvClient(
      '127.0.0.1',
      port: server.port,
      token: 'no',
    ).info();
    expect(r, isA<Unpaired<TvInfo>>());
  });

  test('info reads keysOutside and the API level; an older TV has neither', () {
    final i = TvInfo.fromJson({'keysOutside': 'backHome', 'api': 30});
    expect((i.keysOutside, i.api), ('backHome', 30));
    final old = TvInfo.fromJson({'protocol': 1});
    expect((old.keysOutside, old.api), (null, null));
  });

  test('info parses every field', () async {
    final i = ((await client.info()) as Ok<TvInfo>).value;
    expect(
      (i.protocol, i.version, i.step, i.inFront, i.launcherMode),
      (1, '1.2.3', 'tmdb', true, true),
    );
  });

  test(
    'key: 204 is Ok, 409 is NotInFront with the launcher mode from info',
    () async {
      expect(await client.key(RemoteKey.ok), isA<Ok<void>>());
      inFront = false;
      launcher = false;
      final r = await client.key(RemoteKey.ok);
      expect((r as NotInFront<void>).launcherMode, false);
      launcher = true;
      expect(
        ((await client.key(RemoteKey.up)) as NotInFront<void>).launcherMode,
        true,
      );
    },
  );

  test('an unknown host is Unreachable', () async {
    final r = await TvClient('nonexistent.invalid', token: 't').info();
    expect(r, isA<Unreachable<TvInfo>>());
  });

  test('search parses the three lists', () async {
    final s = ((await client.search('x')) as Ok<SearchResults>).value;
    expect((s.movies.length, s.series.length, s.videos.length), (1, 2, 0));
    expect(s.movies.first['title'], 'T');
  });

  test('rows', () async {
    final r = ((await client.rows()) as Ok<List<TvRow>>).value;
    expect(
      (r.single.key, r.single.title, r.single.items.length),
      ('r', 'Row', 1),
    );
  });

  test('open: 200 is Ok(true), 409 is NotInFront', () async {
    expect(((await client.open(item)) as Ok<bool>).value, true);
    inFront = false;
    expect(await client.open(item), isA<NotInFront<bool>>());
  });

  test('setup calls', () async {
    expect(((await client.setupTmdb('k')) as Ok<String>).value, 'keyBad');
    final p = ((await client.cities('lis')) as Ok<List<Place>>).value.single;
    expect((p.name, p.countryCode, p.lat), ('Lisbon', 'PT', 38.7));
    expect(await client.setCity(p), isA<Ok<void>>());
  });

  test('events gets a state, then ends on bye', () async {
    final got = await client.events().toList();
    expect(got.single.step, 'tmdb');
    expect(got.single.launcherMode, false);
  });

  test('cancelling events closes the socket at once', () async {
    bye = false;
    final first = Completer<void>();
    final sub = client.events().listen((_) => first.complete());
    await first.future;
    // Let the stream settle into waiting for the next message, where a cancel used to go unseen.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await sub.cancel();
    await closed.future.timeout(const Duration(seconds: 1));
  });

  test('a body that is not UTF-8 is Unreachable, not a throw', () async {
    badBody = true;
    expect(await client.info(), isA<Unreachable<TvInfo>>());
  });
}
