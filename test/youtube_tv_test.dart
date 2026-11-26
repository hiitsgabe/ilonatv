import 'dart:async';
import 'dart:io';

import 'package:ilonatv/data/youtube_tv.dart';
import 'package:ilonatv/net.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

String _text(String name) => File('test/fixtures/$name').readAsStringSync();

/// A canned YouTube. [routes] answer a request by the first key its URL
/// contains; each value is a list of answers given in order, the last one
/// again and again. An answer is a fixture name (`yt_...`), a JSON map, other
/// text, a [Future] of
/// one, or something to throw.
class _Net {
  _Net(this.routes);
  final Map<String, List<Object>> routes;
  final posts = <(Uri, Map<String, dynamic>, Map<String, String>)>[];
  final gets = <(Uri, Map<String, String>)>[];
  final _given = <String, int>{};

  Future<Object?> _answer(Uri uri) async {
    for (final MapEntry(:key, :value) in routes.entries) {
      if (!'$uri'.contains(key)) continue;
      final n = _given[key] = (_given[key] ?? -1) + 1;
      final a = value[n < value.length ? n : value.length - 1];
      return switch (a) {
        final Future<Object?> f => await f,
        final Map<String, dynamic> m => m,
        final String name when name.endsWith('.json') => fixture(name),
        final String name when name.startsWith('yt_') => _text(name),
        final String text => text,
        _ => throw a,
      };
    }
    throw StateError('no route for $uri');
  }

  Future<Map<String, dynamic>> post(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    posts.add((uri, body, headers));
    return await _answer(uri) as Map<String, dynamic>;
  }

  Future<String> getText(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    gets.add((uri, headers));
    return await _answer(uri) as String;
  }

  List<String> get postPaths => [for (final p in posts) p.$1.path];
}

const _tv = 'https://www.youtube.com/tv';
const _base =
    'https://www.youtube.com/s/_/kabuki/_/js/k=kabuki.base_cr.en_US.TEST.es6.O/am=AA/d=1/rs=AB/m=base';
const _scrape = {
  'm=base': ['yt_base.js'],
  '/tv': ['yt_tv.html'],
};

Future<MemStore> _withCredentials([
  String id = 'CLIENT_ID',
  String secret = 'SECRET',
]) async {
  final store = MemStore();
  await store.write('youtube_client', {'id': id, 'secret': secret});
  return store;
}

YoutubeTvClient _client(_Net net, Store store) =>
    YoutubeTvClient(store: store, post: net.post, getText: net.getText);

const _code = YtDeviceCode(
  deviceCode: 'DEVICE',
  userCode: 'ABC-DEF-GHIJ',
  verificationUrl: 'https://www.google.com/device',
  interval: 5,
  expiresIn: 1800,
);

HttpStatusException _status(int status, String error) =>
    HttpStatusException(status, '{"error": "$error"}');

void main() {
  group('credentials', () {
    test('are scraped off /tv as the TV, kept, and read back', () async {
      final net = _Net(_scrape);
      final store = MemStore();
      final c = await _client(net, store).credentials();
      expect(
        (c.id, c.secret),
        ('CLIENT_ID.apps.googleusercontent.com', 'SECRET'),
      );
      expect([for (final g in net.gets) '${g.$1}'], [_tv, _base]);
      for (final g in net.gets) {
        expect(g.$2['User-Agent'], kTvUserAgent);
      }
      final kept = (await store.read('youtube_client'))!;
      expect((kept['id'], kept['secret']), (c.id, 'SECRET'));
      final at = DateTime.fromMillisecondsSinceEpoch(kept['at'] as int);
      expect(DateTime.now().difference(at).inSeconds, lessThan(5));

      net.gets.clear();
      final again = await _client(net, store).credentials();
      expect(again.secret, 'SECRET');
      expect(net.gets, isEmpty, reason: 'from the store');
      await _client(net, store).credentials(fresh: true);
      expect(net.gets, isEmpty, reason: 'scraped under 10 minutes ago');

      await store.write('youtube_client', {
        ...kept,
        'at': DateTime.now()
            .subtract(const Duration(minutes: 11))
            .millisecondsSinceEpoch,
      });
      await _client(net, store).credentials(fresh: true);
      expect(net.gets, hasLength(2), reason: 'fresh scrapes an old pair');
    });

    test('callers that need a scrape at once share one', () async {
      final page = Completer<Object?>();
      final net = _Net({
        'm=base': ['yt_base.js'],
        '/tv': [page.future],
      });
      final client = _client(net, MemStore());
      final all = Future.wait([
        client.credentials(),
        client.credentials(fresh: true),
        client.credentials(),
      ]);
      await pumpEventQueue();
      page.complete(_text('yt_tv.html'));
      expect(
        [for (final c in await all) c.secret],
        ['SECRET', 'SECRET', 'SECRET'],
      );
      expect(net.gets, hasLength(2));
    });

    test('the other forms of the page and of base.js', () async {
      final net = _Net({
        'other.js': [
          'x={clientId:"ID-2.apps.googleusercontent.com",\$a:"GOCSPX-SECRET_2"}',
        ],
        '/tv': ['<script id="base-js" src="https://cdn.example/other.js">'],
      });
      final c = await _client(net, MemStore()).credentials();
      expect(
        (c.id, c.secret),
        ('ID-2.apps.googleusercontent.com', 'GOCSPX-SECRET_2'),
      );
      expect('${net.gets.last.$1}', 'https://cdn.example/other.js');
    });

    test('a page without them is a FormatException', () async {
      final noScript = _Net({
        '/tv': ['<html></html>'],
      });
      await expectLater(
        _client(noScript, MemStore()).credentials(),
        throwsFormatException,
      );
      final noPair = _Net({
        'm=base': ['var x = 1;'],
        '/tv': ['yt_tv.html'],
      });
      await expectLater(
        _client(noPair, MemStore()).credentials(),
        throwsFormatException,
      );
    });
  });

  test('deviceCode sends the exact JSON and reads the code', () async {
    final net = _Net({
      'device/code': ['yt_device_code.json'],
    });
    final code = await _client(
      net,
      await _withCredentials(),
    ).deviceCode('UUID');
    final (uri, body, _) = net.posts.single;
    expect('$uri', 'https://www.youtube.com/o/oauth2/device/code');
    expect(body, {
      'client_id': 'CLIENT_ID',
      'device_id': 'UUID',
      'model_name': 'ytlr::',
      'scope': 'http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content',
    });
    expect(
      (code.deviceCode, code.userCode, code.verificationUrl),
      ('DEVICE', 'ABC-DEF-GHIJ', 'https://www.google.com/device'),
    );
    expect((code.interval, code.expiresIn), (5, 1800));
  });

  test('deviceCode asks every second at least, 5 with no interval', () async {
    final device = fixture('yt_device_code.json');
    for (final (interval, expected) in [
      (0, 5),
      (null, 5),
      (-3, 5),
      (1, 1),
      (7, 7),
    ]) {
      final net = _Net({
        'device/code': [
          {...device, 'interval': interval},
        ],
      });
      final code = await _client(net, await _withCredentials()).deviceCode('U');
      expect(code.interval, expected, reason: '$interval');
    }
  });

  group('pollToken', () {
    Future<String?> poll(Object answer) async => _client(
      _Net({
        'oauth2/token': [answer],
      }),
      await _withCredentials(),
    ).pollToken(_code);

    test('pending is null, in a 200 or a 428', () async {
      expect(await poll('yt_token_pending.json'), isNull);
      expect(await poll(const HttpStatusException(428, '')), isNull);
    });

    test('an approval is the refresh token', () async {
      final net = _Net({
        'oauth2/token': ['yt_token_ok.json'],
      });
      final client = _client(net, await _withCredentials());
      expect(await client.pollToken(_code), 'REFRESH');
      expect(net.posts.single.$2, {
        'code': 'DEVICE',
        'client_id': 'CLIENT_ID',
        'client_secret': 'SECRET',
        'grant_type': 'http://oauth.net/grant_type/device/1.0',
      });
      // Its access token is kept: no second call.
      expect(await client.accessToken('REFRESH'), 'ACCESS');
      expect(net.posts, hasLength(1));
    });

    test('a 5xx is the network, not a no', () async {
      await expectLater(
        poll(const HttpStatusException(503, '{"error": "backend_error"}')),
        throwsA(
          isA<HttpStatusException>().having((e) => e.status, 'status', 503),
        ),
      );
    });

    test(
      'an approval with no access token still gives the refresh token',
      () async {
        expect(await poll({'refresh_token': 'REFRESH'}), 'REFRESH');
      },
    );

    test('slow_down, expired_token, access_denied', () async {
      for (final (error, expected) in [
        ('slow_down', YtAuthError.slowDown),
        ('expired_token', YtAuthError.expired),
        ('access_denied', YtAuthError.denied),
      ]) {
        await expectLater(poll({'error': error}), throwsA(expected));
        await expectLater(poll(_status(400, error)), throwsA(expected));
      }
    });
  });

  group('accessToken', () {
    test('is reused until it runs out, and renewed once for all', () async {
      final answer = Completer<Map<String, dynamic>>();
      final net = _Net({
        'oauth2/token': [answer.future],
      });
      final client = _client(net, await _withCredentials());
      final both = Future.wait([
        client.accessToken('REFRESH'),
        client.accessToken('REFRESH'),
      ]);
      answer.complete(fixture('yt_token_ok.json'));
      expect(await both, ['ACCESS', 'ACCESS']);
      expect(await client.accessToken('REFRESH'), 'ACCESS');
      expect(net.posts, hasLength(1));
      expect(net.posts.single.$2, {
        'refresh_token': 'REFRESH',
        'client_id': 'CLIENT_ID',
        'client_secret': 'SECRET',
        'grant_type': 'refresh_token',
      });
    });

    test('one with under a minute left is renewed', () async {
      final net = _Net({
        'oauth2/token': [
          {'access_token': 'A1', 'expires_in': 59},
          {'access_token': 'A2', 'expires_in': 3599},
        ],
      });
      final client = _client(net, await _withCredentials());
      expect(await client.accessToken('REFRESH'), 'A1');
      expect(await client.accessToken('REFRESH'), 'A2');
      expect(await client.accessToken('REFRESH'), 'A2');
      expect(net.posts, hasLength(2));
    });

    test('invalid_grant is revoked', () async {
      final net = _Net({
        'oauth2/token': [_status(400, 'invalid_grant')],
      });
      await expectLater(
        _client(net, await _withCredentials()).accessToken('REFRESH'),
        throwsA(YtAuthError.revoked),
      );
    });

    test('a refused client is scraped again, once', () async {
      for (final refused in [
        _status(401, 'invalid_client'),
        {'error': 'invalid_client'},
      ]) {
        final net = _Net({
          'oauth2/token': [refused, 'yt_token_ok.json'],
          ..._scrape,
        });
        final store = await _withCredentials('OLD', 'OLD_SECRET');
        expect(await _client(net, store).accessToken('REFRESH'), 'ACCESS');
        expect(
          [for (final p in net.posts) p.$2['client_id']],
          ['OLD', 'CLIENT_ID.apps.googleusercontent.com'],
        );
        expect((await store.read('youtube_client'))!['secret'], 'SECRET');
      }

      final always = _Net({
        'oauth2/token': [_status(401, 'invalid_client')],
        ..._scrape,
      });
      await expectLater(
        _client(always, await _withCredentials()).accessToken('REFRESH'),
        throwsA(anything),
      );
      expect(always.posts, hasLength(2), reason: 'once, not forever');
    });
  });

  test('accounts reads the owner and the brand, as the TV', () async {
    final net = _Net({
      'oauth2/token': ['yt_token_ok.json'],
      'accounts_list': ['yt_accounts_list.json'],
    });
    final accounts = await _client(
      net,
      await _withCredentials(),
    ).accounts('REFRESH');
    expect(
      [for (final a in accounts) a.toJson()],
      [
        {
          'refreshToken': 'REFRESH',
          'name': 'Alex',
          'avatarUrl': 'https://yt3.ggpht.com/owner=s240',
          'pageId': null,
          'enabled': true,
        },
        {
          'refreshToken': 'REFRESH',
          'name': 'Alex Kids',
          'avatarUrl': 'https://yt3.ggpht.com/kids=s88',
          'pageId': 'PAGE_KIDS',
          'enabled': true,
        },
      ],
    );
    final (uri, body, headers) = net.posts.last;
    expect(
      '$uri',
      'https://www.youtube.com/youtubei/v1/account/accounts_list?prettyPrint=false',
    );
    expect(body['accountReadMask'], {
      'returnOwner': true,
      'returnBrandAccounts': true,
      'returnPersonaAccounts': false,
    });
    expect(body['context']['client']['clientName'], 'TVHTML5');
    expect(body['context']['client']['clientVersion'], kTvClientVersion);
    expect(headers, {
      'User-Agent': kTvUserAgent,
      'Referer': 'https://www.youtube.com/tv',
      'Authorization': 'Bearer ACCESS',
    });
    expect(parseAccounts({'contents': []}, 'R'), isEmpty);
  });

  test('YtAccount JSON round trip; no enabled reads as true', () {
    const a = YtAccount(
      refreshToken: 'R',
      name: 'N',
      avatarUrl: 'https://a',
      pageId: 'P',
      enabled: false,
    );
    expect(YtAccount.fromJson(a.toJson()).toJson(), a.toJson());
    expect(a.copyWith(enabled: true).enabled, isTrue);
    expect(a.copyWith().enabled, isFalse);
    expect(
      YtAccount.fromJson({'refreshToken': 'R', 'name': 'N'}).enabled,
      isTrue,
    );
  });

  group('YoutubeSignIn', () {
    late Settings settings;
    late FakeTimerZone zone;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      zone = FakeTimerZone();
    });

    Future<YoutubeSignIn> started(List<Object> token) async {
      final net = _Net({
        'device/code': ['yt_device_code.json'],
        'accounts_list': ['yt_accounts_list.json'],
        'oauth2/token': token,
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      return s;
    }

    test('an approval gives the choices and adds nothing', () async {
      final s = await started(['yt_token_pending.json', 'yt_token_ok.json']);
      expect(s.code!.userCode, 'ABC-DEF-GHIJ');
      expect(zone.timers.single.period, const Duration(seconds: 5));
      await zone.timers.single.fireAndSettle();
      expect(s.choices, isNull);
      await zone.timers.single.fireAndSettle();
      expect([for (final a in s.choices!) a.name], ['Alex', 'Alex Kids']);
      expect(zone.timers.single.isActive, isFalse, reason: 'done asking');
      expect(settings.youtubeAccounts, isEmpty);
      expect(s.code, isNotNull, reason: 'until something is chosen');
    });

    test(
      'addChosen adds only the chosen, enabled, without duplicates',
      () async {
        settings.youtubeAccounts = [
          const YtAccount(refreshToken: 'OLD', name: 'Other', pageId: 'P2'),
          const YtAccount(
            refreshToken: 'OLD',
            name: 'Kids renamed',
            pageId: 'PAGE_KIDS',
            enabled: false,
          ),
        ];
        final s = await started(['yt_token_ok.json']);
        await zone.timers.single.fireAndSettle();
        await s.addChosen([s.choices![1].copyWith(enabled: false)]);
        expect(
          [for (final a in settings.youtubeAccounts) a.toJson()],
          [
            settings.youtubeAccounts[0].toJson(),
            {
              'refreshToken': 'REFRESH',
              'name': 'Alex Kids',
              'avatarUrl': 'https://yt3.ggpht.com/kids=s88',
              'pageId': 'PAGE_KIDS',
              'enabled': true,
            },
          ],
        );
        expect((s.code, s.choices), (null, null));
        final saved = await Settings.load();
        expect(saved.youtubeAccounts.map((a) => a.name), [
          'Other',
          'Alex Kids',
        ]);

        // The owner twice: once.
        await s.addChosen([
          const YtAccount(refreshToken: 'R', name: 'Alex'),
          const YtAccount(refreshToken: 'R2', name: 'Alex'),
        ]);
        expect(settings.youtubeAccounts.map((a) => a.name), [
          'Other',
          'Alex Kids',
          'Alex',
        ]);
        expect(settings.youtubeAccounts.last.refreshToken, 'R2');
      },
    );

    test('cancel with choices adds nothing', () async {
      final s = await started(['yt_token_ok.json']);
      await zone.timers.single.fireAndSettle();
      expect(s.choices, isNotEmpty);
      s.cancel();
      expect((s.code, s.choices), (null, null));
      expect(settings.youtubeAccounts, isEmpty);
    });

    test('stop and cancel end the asking', () async {
      for (final end in [(YoutubeSignIn s) => s.stop(), (s) => s.cancel()]) {
        zone = FakeTimerZone();
        final s = await started(['yt_token_pending.json']);
        end(s);
        expect(s.code, isNull);
        expect(zone.timers.single.isActive, isFalse);
      }
    });

    test('an approval that arrives after cancel is dropped', () async {
      final answer = Completer<Map<String, dynamic>>();
      final s = await started([answer.future, 'yt_token_pending.json']);
      zone.timers.single.fire();
      s.cancel();
      answer.complete(fixture('yt_token_ok.json'));
      await pumpEventQueue();
      expect((s.code, s.choices, s.error), (null, null, null));

      // Nor does it carry over to the next sign-in, started before it came.
      final again = Completer<Map<String, dynamic>>();
      zone = FakeTimerZone();
      final t = await started([again.future, 'yt_token_pending.json']);
      zone.timers.single.fire();
      t.cancel();
      await zone.run(t.start);
      again.complete(fixture('yt_token_ok.json'));
      await pumpEventQueue();
      await zone.timers.last.fireAndSettle();
      expect(t.code, isNotNull);
      expect(t.choices, isNull, reason: 'the new code is still pending');
    });

    test('a code that arrives after cancel is dropped', () async {
      final answer = Completer<Map<String, dynamic>>();
      final net = _Net({
        'device/code': [answer.future],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      final starting = zone.run(s.start);
      await pumpEventQueue();
      s.cancel();
      answer.complete(fixture('yt_device_code.json'));
      await starting;
      expect(s.code, isNull);
      expect(zone.timers, isEmpty);
    });

    test('a refusal that arrives after cancel or stop is dropped', () async {
      for (final end in [(YoutubeSignIn s) => s.cancel(), (s) => s.stop()]) {
        for (final error in ['slow_down', 'expired_token']) {
          zone = FakeTimerZone();
          final answer = Completer<Map<String, dynamic>>();
          final s = await started([answer.future]);
          zone.timers.single.fire();
          end(s);
          answer.complete({'error': error});
          await pumpEventQueue();
          expect(zone.timers.where((t) => t.isActive), isEmpty, reason: error);
          expect((s.code, s.error), (null, null), reason: error);
        }
      }
    });

    test('profiles that failed are not carried to the next sign-in', () async {
      final net = _Net({
        'device/code': ['yt_device_code.json'],
        'accounts_list': [
          const SocketException('offline'),
          'yt_accounts_list.json',
        ],
        'oauth2/token': ['yt_token_ok.json', 'yt_token_pending.json'],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      await zone.timers.single.fireAndSettle();
      expect(s.choices, isNull, reason: 'approved, profiles failed');
      s.cancel();
      await zone.run(s.start);
      await zone.timers.last.fireAndSettle();
      expect(s.choices, isNull, reason: 'the new code is pending');
      expect(s.code, isNotNull);
    });

    test('a code that fails after cancel shows no error', () async {
      final answer = Completer<Map<String, dynamic>>();
      final net = _Net({
        'device/code': [answer.future],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      final starting = zone.run(s.start);
      await pumpEventQueue();
      s.cancel();
      answer.completeError(const SocketException('offline'));
      await starting;
      expect((s.code, s.error), (null, null));
    });

    test('start clears the error and says so at once', () async {
      final answer = Completer<Map<String, dynamic>>();
      final net = _Net({
        'device/code': [const SocketException('offline'), answer.future],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      expect(s.error, 'network');
      String? heard = 'none';
      s.addListener(() => heard = s.error);
      final starting = zone.run(s.start);
      expect(heard, isNull, reason: 'before the code is back');
      answer.complete(fixture('yt_device_code.json'));
      await starting;
    });

    test('a 5xx on a tick keeps asking', () async {
      final s = await started([
        const HttpStatusException(502, 'Bad Gateway'),
        'yt_token_ok.json',
      ]);
      await zone.timers.single.fireAndSettle();
      expect(s.code, isNotNull);
      expect(s.error, isNull);
      await zone.timers.single.fireAndSettle();
      expect(s.choices, hasLength(2));
    });

    test('an approval outlives the code running out', () async {
      final net = _Net({
        'device/code': [
          {...fixture('yt_device_code.json'), 'expires_in': 10},
        ],
        'accounts_list': [
          const SocketException('offline'),
          const SocketException('offline'),
          const SocketException('offline'),
          'yt_accounts_list.json',
        ],
        'oauth2/token': ['yt_token_ok.json'],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      for (var i = 0; i < 3; i++) {
        await zone.timers.single.fireAndSettle();
        expect((s.error, s.choices), (null, null), reason: 'tick ${i + 1}');
        expect(s.code, isNotNull);
      }
      await zone.timers.single.fireAndSettle();
      expect(s.choices, hasLength(2));
    });

    test('profiles that arrive after cancel are dropped', () async {
      final profiles = Completer<Map<String, dynamic>>();
      final net = _Net({
        'device/code': ['yt_device_code.json'],
        'accounts_list': [profiles.future],
        'oauth2/token': ['yt_token_ok.json'],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      zone.timers.single.fire();
      await pumpEventQueue();
      s.cancel();
      profiles.complete(fixture('yt_accounts_list.json'));
      await pumpEventQueue();
      expect((s.code, s.choices), (null, null));
    });

    test(
      'slow_down waits 5 s more; the network failing does not stop',
      () async {
        final s = await started([
          {'error': 'slow_down'},
          const SocketException('offline'),
          'yt_token_ok.json',
        ]);
        await zone.timers.single.fireAndSettle();
        expect(zone.timers.last.period, const Duration(seconds: 10));
        expect(zone.timers.first.isActive, isFalse);
        await zone.timers.last.fireAndSettle();
        expect(s.code, isNotNull);
        await zone.timers.last.fireAndSettle();
        expect(s.choices, hasLength(2));
      },
    );

    test('accounts failing after an approval asks for them again', () async {
      final net = _Net({
        'device/code': ['yt_device_code.json'],
        'accounts_list': [
          const SocketException('offline'),
          'yt_accounts_list.json',
        ],
        'oauth2/token': ['yt_token_ok.json', 'yt_token_pending.json'],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      await zone.timers.single.fireAndSettle();
      expect(s.choices, isNull);
      await zone.timers.single.fireAndSettle();
      expect(s.choices, hasLength(2));
      expect(
        net.postPaths.where((p) => p.endsWith('token')),
        hasLength(1),
        reason: 'the code is exchanged once',
      );
    });

    test('expired_token, a no, or expires_in passing end with why', () async {
      final expired = await started([
        {'error': 'expired_token'},
      ]);
      await zone.timers.single.fireAndSettle();
      expect((expired.code, expired.error), (null, 'expired'));

      zone = FakeTimerZone();
      final denied = await started([_status(403, 'access_denied')]);
      await zone.timers.single.fireAndSettle();
      expect((denied.code, denied.error), (null, 'denied'));

      zone = FakeTimerZone();
      final late = await started(['yt_token_pending.json']);
      for (var i = 0; i < 1800 ~/ 5 - 1; i++) {
        await zone.timers.single.fireAndSettle();
      }
      expect(late.code, isNotNull);
      await zone.timers.single.fireAndSettle();
      expect((late.code, late.error), (null, 'expired'));
      expect(zone.timers.single.isActive, isFalse);
    });

    test('no code is a network error, and start clears it', () async {
      final net = _Net({
        'device/code': [
          const SocketException('offline'),
          'yt_device_code.json',
        ],
      });
      final s = YoutubeSignIn(settings, _client(net, await _withCredentials()));
      await zone.run(s.start);
      expect((s.code, s.error), (null, 'network'));
      expect(zone.timers, isEmpty);
      await zone.run(s.start);
      expect((s.code?.userCode, s.error), ('ABC-DEF-GHIJ', null));
    });
  });
}
