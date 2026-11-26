import 'dart:async';
import 'dart:io';

import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/stremio.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/net.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _routes = {'datastoreGet': 'stremio_library.json'};

const _api = 'https://api.strem.io/api';

/// What the fixture's library shows under "Continue watching", newest first.
const _row = ['tt1', 'tt2', 'tt4', 'tt7', 'tt8'];

List<String> _ids(Iterable<MediaItem> items) => [for (final i in items) i.id];

Post _failing(Object error) =>
    (uri, body, {headers = const {}}) async => throw error;

/// A [Fetch] that answers every request with what [reply] makes of it.
Fetch _answering(Future<Map<String, dynamic>> Function(Uri uri) reply) =>
    (uri, {headers = const {}}) => reply(uri);

/// A library entry as Stremio sends it: in progress, unless told otherwise.
Map<String, dynamic> _entry(
  String id, {
  String type = 'movie',
  String mtime = '2026-10-30T20:00:00.000Z',
  int offset = 1000,
  String? videoId,
}) => {
  '_id': id,
  'name': 'Title $id',
  'type': type,
  'poster': 'https://images.example/$id.jpg',
  'removed': false,
  'temp': false,
  '_mtime': mtime,
  'state': {'timeOffset': offset, 'duration': 8000000, 'video_id': videoId},
};

void main() {
  tearDown(() => I18n.language = 'en');

  group('StremioClient', () {
    test('any other failure of the call passes through as it is', () async {
      final offline = StremioClient(
        post: _failing(const SocketException('offline')),
      );
      await expectLater(
        offline.userEmail('AK'),
        throwsA(isA<SocketException>()),
      );
      await expectLater(offline.library('AK'), throwsA(isA<SocketException>()));

      // A 200 that is not Stremio's answer is no answer, and no StremioError.
      final odd = StremioClient(
        post: (uri, body, {headers = const {}}) async => {'oops': true},
      );
      final notStremio = throwsA(isNot(isA<StremioError>()));
      await expectLater(odd.userEmail('AK'), notStremio);
      await expectLater(odd.library('AK'), notStremio);
    });

    test('library posts datastoreGet and skips bad items', () async {
      final net = fakePost(_routes);

      final items = await StremioClient(post: net.call).library('AK');

      final (uri, body) = net.calls.single;
      expect(uri.toString(), '$_api/datastoreGet');
      expect(body, {
        'authKey': 'AK',
        'collection': 'libraryItem',
        'ids': [],
        'all': true,
      });
      // Eight items, in the order of the answer, and one entry that is no
      // item: `{"_id": 42}`.
      expect(items.map((i) => i.id), [
        'tt3',
        'tt8',
        'tt6',
        'tt2',
        'tt5',
        'tt1',
        'tt7',
        'tt4',
      ]);
    });

    test('an error reply to the library is a StremioError too', () async {
      final client = StremioClient(
        post: (uri, body, {headers = const {}}) async => {
          'error': {'message': 'Session does not exist', 'code': 1},
        },
      );

      await expectLater(
        client.library('AK'),
        throwsA(
          isA<StremioError>()
              .having((e) => e.message, 'message', 'Session does not exist')
              .having((e) => e.code, 'code', 1),
        ),
      );
    });
  });

  group('sports catalogs', () {
    const live = 'https://sports.example/u1/catalog/tv/live_now.json';
    const events =
        'https://sports.example/u1/catalog/events/football%20br.json';
    final catalogs = fake({
      '/catalog/tv/live_now.json': 'stremio_catalog_live.json',
      '/catalog/events/': 'stremio_catalog_events.json',
    });

    test(
      'addons: the catalogs not of films or series, nor needing an extra',
      () async {
        final net = fakePost({
          'addonCollectionGet': 'stremio_addon_collection.json',
        });
        final urls = await StremioClient(post: net.call).addons('AK');
        expect(urls.map((u) => '$u'), [live, events]);
        final (uri, body) = net.calls.single;
        expect('$uri', '$_api/addonCollectionGet');
        expect(body, {
          'type': 'AddonCollectionGet',
          'authKey': 'AK',
          'update': true,
        });
      },
    );

    test('catalog: its items, one with no id left out', () async {
      final items = await StremioClient(get: catalogs.call)
          .catalog(Uri.parse(live));
      expect(
        [for (final i in items) '${i.type}/${i.id} ${i.name}'],
        ['tv/ch5 Sports 5', 'tv/ch1 Sports 1'],
      );
      expect(items[1].description, 'NBA: Boston Celtics @ Toronto Raptors');
    });

    test(
      'SportsCatalogs keeps a whole answer 10 minutes, per account',
      () async {
        var now = DateTime.utc(2026, 11, 1, 12);
        final posts = fakePost({
          'addonCollectionGet': 'stremio_addon_collection.json',
        });
        final sports = SportsCatalogs(
          client: StremioClient(post: posts.call, get: catalogs.call),
          now: () => now,
        );
        expect((await sports.items('AK')).map((i) => i.id), [
          'ch5',
          'ch1',
          'ev:pal-vas',
          'ev:gre-cam',
        ]);
        now = now.add(const Duration(minutes: 9));
        await sports.items('AK');
        expect(posts.calls, hasLength(1));
        now = now.add(const Duration(minutes: 1));
        await sports.items('AK');
        expect(posts.calls, hasLength(2));
        await sports.items('OTHER');
        expect(posts.calls, hasLength(3));
        expect(posts.calls.last.$2['authKey'], 'OTHER');
      },
    );

    test(
      'a failing or slow catalog is left out, and the answer kept 1 minute',
      () async {
        var now = DateTime.utc(2026, 11, 1, 12);
        final posts = fakePost({
          'addonCollectionGet': 'stremio_addon_collection.json',
        });
        var slow = true;
        final sports = SportsCatalogs(
          client: StremioClient(
            post: posts.call,
            get: (uri, {headers = const {}}) {
              // The events catalog never answers the first time.
              if (uri.path.contains('events') && slow) {
                return Completer<Map<String, dynamic>>().future;
              }
              return catalogs.call(uri);
            },
          ),
          now: () => now,
          wait: const Duration(milliseconds: 20),
        );
        expect((await sports.items('AK')).map((i) => i.id), ['ch5', 'ch1']);
        now = now.add(const Duration(seconds: 59));
        await sports.items('AK');
        expect(posts.calls, hasLength(1));
        slow = false;
        now = now.add(const Duration(seconds: 1));
        expect(await sports.items('AK'), hasLength(4));
        expect(posts.calls, hasLength(2));
      },
    );

    test('two asks while one is out share it', () async {
      catalogs.calls.clear();
      final posts = fakePost({
        'addonCollectionGet': 'stremio_addon_collection.json',
      });
      final sports = SportsCatalogs(
        client: StremioClient(post: posts.call, get: catalogs.call),
      );
      final first = sports.items('AK');
      final second = sports.items('AK');
      expect(await second, hasLength(4));
      expect(await first, hasLength(4));
      expect(posts.calls, hasLength(1));
      expect(catalogs.calls, hasLength(2));
    });
  });

  group('the library', () {
    test('LibraryItem reads the fields', () {
      final byId = {
        for (final i in parseLibrary(fixture('stremio_library.json'))) i.id: i,
      };

      final series = byId['tt2']!;
      expect(series.name, 'In Progress Series');
      expect(series.type, 'series');
      expect(series.poster, 'https://images.example/tt2.jpg');
      expect([series.removed, series.temp], [false, false]);
      expect(series.mtime, DateTime.utc(2026, 10, 29, 21, 30));
      expect(series.timeOffset, 900000);
      expect(series.videoId, 'tt2:2:5');

      expect([byId['tt4']!.removed, byId['tt4']!.temp], [true, true]);
      // An empty poster, an empty video id and a null one all read as none.
      expect(byId['tt7']!.poster, isNull);
      expect([byId['tt7']!.videoId, byId['tt8']!.videoId], [isNull, isNull]);
      expect(byId['tt6']!.timeOffset, 0);
    });

    test('an entry that cannot be read is skipped, the others stay', () {
      Map<String, dynamic> without(String key) => _entry('tt$key')..remove(key);

      final items = parseLibrary({
        'result': [
          _entry('tt1'),
          {'_id': 42},
          'junk',
          null,
          without('_id'),
          without('name'),
          without('type'),
          without('_mtime'),
          _entry('tt2', mtime: 'yesterday'),
          _entry('tt3'),
        ],
      });

      expect(items.map((i) => i.id), ['tt1', 'tt3']);
    });

    test('only four keys are needed; the rest has a default', () {
      Map<String, dynamic> bare() => {
        '_id': 'tt1',
        'name': 'One',
        'type': 'movie',
        '_mtime': '2026-10-30T20:00:00.000Z',
      };

      // Not watched, not removed: kept in the library, out of the row.
      final unwatched = parseLibrary({
        'result': [bare()],
      }).single;
      expect(
        [unwatched.removed, unwatched.temp, unwatched.timeOffset],
        [false, false, 0],
      );
      expect(unwatched.poster, isNull);
      expect(unwatched.videoId, isNull);
      expect(continueWatching([unwatched]), isEmpty);

      // Watched, with no removed or temp in the entry: in the row.
      final watched = parseLibrary({
        'result': [
          bare()..['state'] = {'timeOffset': 5},
        ],
      });
      expect(_ids(continueWatching(watched)), ['tt1']);
    });

    test(
      'continueWatching filters, sorts by mtime desc, limits and subtitles',
      () {
        final items = parseLibrary(fixture('stremio_library.json'));
        final cw = continueWatching(items);

        // Newest first. Out: tt3 (removed), tt5 (another type) and tt6 (never
        // played), the first two newer than most of the rest. tt4 is removed
        // but temp, so it stays.
        expect(cw.map((m) => m.id), _row);
        expect(cw.first.toJson(), {
          'type': 'movie',
          'id': 'tt1',
          'title': 'In Progress Movie',
          'year': null,
          'genre': '',
          'rating': null,
          'posterUrl': 'https://images.example/tt1.jpg',
          'backdropUrl':
              'https://images.metahub.space/background/medium/tt1/img',
          'imdbId': 'tt1',
          'videoId': 'tt1',
          'subtitle': null,
        });
        I18n.language = 'en';
        expect(continueWatching(items)[1].subtitle, 'S2 · E5');
        I18n.language = 'pt';
        expect(continueWatching(items)[1].subtitle, 'T2 · E5');
        expect(cw[1].type, MediaType.series);
        expect(cw[1].videoId, 'tt2:2:5');
        expect(cw[3].posterUrl, isNull);
        expect(cw.first.imdbId, 'tt1');
        expect(cw.last.videoId, isNull);
      },
    );

    test('continueWatching keeps the 20 most recent', () {
      final items = parseLibrary({
        'result': [
          // The oldest first, so the sort has work to do.
          for (var i = 0; i < 25; i++)
            _entry(
              'tt$i',
              mtime: DateTime.utc(2026, 10, 30, 12, i).toIso8601String(),
            ),
        ],
      });

      expect(_ids(continueWatching(items)), [
        for (var i = 24; i >= 5; i--) 'tt$i',
      ]);
    });

    test('every library id is what Stremio opens, an add-on id too', () {
      final items = parseLibrary({
        'result': [_entry('tt1'), _entry('kitsu:7442', type: 'series')],
      });

      expect(continueWatching(items).map((m) => m.imdbId), [
        'tt1',
        'kitsu:7442',
      ]);
    });

    test(
      'the subtitle needs a series with a video id <id>:<season>:<episode>',
      () {
        String? subtitle(String type, String id, String? videoId) {
          final items = parseLibrary({
            'result': [_entry(id, type: type, videoId: videoId)],
          });
          return continueWatching(items).single.subtitle;
        }

        expect(subtitle('series', 'tt2', 'tt2:2:5'), 'S2 · E5');
        expect(subtitle('series', 'tt2', 'tt2:0:12'), 'S0 · E12');
        // An id with a colon of its own, as an add-on's can have.
        expect(subtitle('series', 'kitsu:7442', 'kitsu:7442:1:3'), 'S1 · E3');
        expect(subtitle('series', 'kitsu:7442', 'kitsu:7442:3'), isNull);
        for (final videoId in [
          null,
          'tt2',
          'tt2:2',
          'tt2:2:5:7',
          'tt2:x:5',
          'tt2:2:y',
          'tt2::5',
          'tt9:2:5',
        ]) {
          expect(
            subtitle('series', 'tt2', videoId),
            isNull,
            reason: '$videoId',
          );
        }
        expect(subtitle('movie', 'tt1', 'tt1:2:5'), isNull);
      },
    );

    test('seasonEpisode follows the UI language', () {
      expect(seasonEpisode(2, 5), 'S2 · E5');
      I18n.language = 'pt';
      expect(seasonEpisode(2, 5), 'T2 · E5');
      expect(seasonEpisode(10, 12), 'T10 · E12');
    });
  });

  group('StremioSource', () {
    late Directory dir;
    late Settings settings;
    late Store store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      settings.stremioAuthKey = 'AK';
      dir = await Directory.systemTemp.createTemp('ilonatv');
      store = Store(dir);
    });
    tearDown(() => dir.delete(recursive: true));

    StremioSource source(Post post, [Store? on, Fetch get = getJson]) =>
        StremioSource(
          settings,
          on ?? store,
          client: StremioClient(post: post, get: get),
        );

    File cacheFile() => File('${dir.path}/cache/stremio.json');

    test('without an authKey nothing is asked and the row is empty', () async {
      settings.stremioAuthKey = '';
      final net = fakePost(_routes);
      final s = source(net.call);
      var heard = 0;
      s.addListener(() => heard++);

      await s.refresh();
      await s.refresh(force: true);

      expect(net.calls, isEmpty);
      expect(s.continueWatching, isEmpty);
      expect([s.error, heard], [null, 0]);

      // A row left behind by an account that is gone goes with its key.
      await store.write('stremio', {
        'items': [
          {'type': 'movie', 'id': 'tt1', 'title': 'Old'},
        ],
      });
      await s.loadCache();
      expect(s.continueWatching, hasLength(1));
      await s.refresh();
      expect(s.continueWatching, isEmpty);
      expect(net.calls, isEmpty);
    });

    test(
      'with an authKey it asks, caches the row and trusts it for 15 minutes',
      () async {
        final net = fakePost(_routes);
        final s = source(net.call);
        var heard = 0;
        s.addListener(() => heard++);
        void age(Duration d) =>
            cacheFile().setLastModifiedSync(DateTime.now().subtract(d));

        await s.refresh();

        final (uri, body) = net.calls.single;
        expect(uri.toString(), '$_api/datastoreGet');
        expect(body['authKey'], 'AK');
        expect(_ids(s.continueWatching), _row);
        expect(s.error, isNull);
        expect(heard, 1);
        expect(await store.read('stremio'), {
          'items': [for (final m in s.continueWatching) m.toJson()],
        });

        await s.refresh();
        expect(net.calls, hasLength(1), reason: 'just written');

        age(const Duration(minutes: 14));
        await s.refresh();
        expect(net.calls, hasLength(1), reason: '14 minutes old');

        age(const Duration(minutes: 16));
        await s.refresh();
        expect(net.calls, hasLength(2), reason: '16 minutes old');
        // The same row again still made the cache young.
        expect(
          DateTime.now().difference((await store.writtenAt('stremio'))!),
          lessThan(const Duration(minutes: 1)),
        );

        age(const Duration(minutes: -5));
        await s.refresh();
        expect(net.calls, hasLength(3), reason: 'written in the future');

        await s.refresh(force: true);
        expect(net.calls, hasLength(4), reason: 'forced');
      },
    );

    test(
      'a restart shows the cache of any age and does not ask while it is fresh',
      () async {
        await source(fakePost(_routes).call)
            .refresh(); // what the last run left
        final net = fakePost(_routes);
        final s = source(net.call);
        expect(s.continueWatching, isEmpty);
        var heard = 0;
        s.addListener(() => heard++);

        await s.loadCache();
        expect(_ids(s.continueWatching), _row);
        expect(heard, 1);
        expect(s.continueWatching[1].subtitle, 'S2 · E5');
        await s.refresh();
        expect(net.calls, isEmpty, reason: 'fresh');

        // A month old: still what the home opens with, and now it is asked.
        cacheFile().setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 30)),
        );
        final later = source(net.call);
        await later.loadCache();
        expect(later.continueWatching, hasLength(5));
        await later.refresh();
        expect(net.calls, hasLength(1));
      },
    );

    test('a cache this version cannot read is skipped', () async {
      final good = {'type': 'movie', 'id': 'tt1', 'title': 'One'};
      for (final bad in <Map<String, dynamic>>[
        {},
        {'items': 'x'},
        {
          'items': [
            {'type': 'movie'},
          ],
        },
        // All or nothing: the good item is not shown on its own.
        {
          'items': [
            good,
            {'type': 'movie'},
          ],
        },
      ]) {
        await store.write('stremio', bad);
        final s = source(fakePost({}).call);

        await s.loadCache();

        expect(s.continueWatching, isEmpty, reason: '$bad');
      }

      await store.write('stremio', {
        'items': [good],
      });
      final s = source(fakePost({}).call);
      await s.loadCache();
      expect(_ids(s.continueWatching), ['tt1']);
    });

    test('whatever goes wrong, the row stays and error says what', () async {
      await source(fakePost(_routes).call).refresh();
      final cached = await store.read('stremio');
      final failures = <(Post, String)>[
        (_failing(const SocketException('offline')), 'network'),
        (_failing(TimeoutException('slow')), 'network'),
        (_failing(const HttpStatusException(500, 'oops')), 'network'),
        (_failing(const FormatException('html')), 'network'),
        (_failing(const HandshakeException('tls')), 'network'),
        // A 200 that is not Stremio's answer, or not a library.
        ((uri, body, {headers = const {}}) async => {'oops': true}, 'network'),
        ((uri, body, {headers = const {}}) async => {'result': 'x'}, 'network'),
        // Stremio's own word for it.
        (
          (uri, body, {headers = const {}}) async => {
            'error': {'message': 'Session does not exist', 'code': 1},
          },
          'Session does not exist',
        ),
      ];

      for (final (post, message) in failures) {
        final s = source(post);
        await s.loadCache();

        await s.refresh(force: true);

        expect(s.error, message);
        expect(_ids(s.continueWatching), _row, reason: message);
        expect(await store.read('stremio'), cached, reason: message);
      }
    });

    test('listeners hear a new error once, and every row', () async {
      final good = fakePost(_routes);
      Post reply = _failing(const SocketException('offline'));
      final s = source((uri, body, {headers = const {}}) => reply(uri, body));
      var heard = 0;
      s.addListener(() => heard++);

      await s.refresh();
      expect([s.error, heard], ['network', 1]);
      await s.refresh();
      expect(heard, 1, reason: 'the same error again');

      reply = good.call;
      await s.refresh();
      expect([s.error, heard], [null, 2]);
      await s.refresh(force: true);
      expect(heard, 3);
    });

    test('a cache that will not write does not fail a good fetch', () async {
      final s = source(fakePost(_routes).call, FullDiskStore(dir));

      await s.refresh();

      expect(s.error, isNull);
      expect(_ids(s.continueWatching), _row);
      expect(await store.read('stremio'), isNull);
    });

    test('logout forgets the account, its cache and its row', () async {
      final good = fakePost(_routes);
      Post reply = good.call;
      final s = source((uri, body, {headers = const {}}) => reply(uri, body));
      settings.stremioEmail = 'a@b';
      await s.refresh(force: true);
      reply = _failing(const SocketException('offline'));
      await s.refresh(force: true);
      expect(s.error, 'network', reason: 'an error to forget');
      expect(await store.read('stremio'), isNotNull);
      good.calls.clear();
      var heard = 0;
      s.addListener(() => heard++);

      await s.logout();

      expect([settings.stremioAuthKey, settings.stremioEmail], ['', '']);
      final saved = await Settings.load();
      expect([saved.stremioAuthKey, saved.stremioEmail], ['', '']);
      expect(await store.read('stremio'), isNull);
      expect(s.continueWatching, isEmpty);
      expect(s.seeds, isEmpty);
      expect(s.error, isNull);
      expect(heard, 1);

      reply = good.call;
      await s.refresh(force: true);
      expect(good.calls, isEmpty, reason: 'no account, no call');
      await s.logout(); // already out: fine
    });

    test(
      'a row that arrives after logout is dropped, not shown or cached',
      () async {
        final answer = Completer<Map<String, dynamic>>();
        final s = source((uri, body, {headers = const {}}) => answer.future);
        var heard = 0;
        s.addListener(() => heard++);

        final pending = s.refresh(force: true);
        await s.logout();
        answer.complete(fixture('stremio_library.json'));
        await pending;

        expect(s.continueWatching, isEmpty);
        expect(await store.read('stremio'), isNull);
        expect(heard, 1, reason: 'the logout, and nothing after it');
      },
    );

    test(
      'an answer for a key that was replaced is dropped, its error too',
      () async {
        for (final answer in <Future<Map<String, dynamic>> Function()>[
          () async => fixture('stremio_library.json'),
          () async => throw const SocketException('offline'),
        ]) {
          final gate = Completer<void>();
          final s = source((uri, body, {headers = const {}}) async {
            await gate.future;
            return answer();
          });
          var heard = 0;
          s.addListener(() => heard++);

          final pending = s.refresh(force: true);
          settings.stremioAuthKey = 'BK'; // what a login as someone else does
          gate.complete();
          await pending;
          settings.stremioAuthKey = 'AK';

          expect(s.continueWatching, isEmpty);
          expect([s.error, heard], [null, 0]);
          expect(await store.read('stremio'), isNull);
        }
      },
    );

    test('seeds are the first five IMDb ids, in order', () async {
      final entries = [
        // The newest first: the row keeps this order.
        for (final (i, id) in [
          'tt1',
          'tt2',
          'kitsu:1',
          'tt3',
          'tt4',
          'tt5',
          'tt6',
          'tt7',
        ].indexed)
          _entry(
            id,
            mtime: DateTime.utc(2026, 10, 30, 12, 30 - i).toIso8601String(),
          ),
      ];
      final s = source(
        (uri, body, {headers = const {}}) async => {'result': entries},
      );
      expect(s.seeds, isEmpty);

      await s.refresh();

      expect(s.continueWatching, hasLength(8));
      // kitsu:1 opens in Stremio by its id, but TMDB cannot start from it.
      expect(s.continueWatching[2].imdbId, 'kitsu:1');
      expect(s.seeds, ['tt1', 'tt2', 'tt3', 'tt4', 'tt5']);
    });

    test(
      'start arms one 15 minute timer whose tick refetches; stop cancels',
      () async {
        final zone = FakeTimerZone();
        final net = fakePost(_routes);
        final s = source(net.call, MemStore());

        await zone.run(() async {
          s.stop(); // never started: nothing to cancel
          s.start();
          await pumpEventQueue();
          expect(net.calls, hasLength(1), reason: 'start refreshes at once');
          s.start();
          await pumpEventQueue();
          expect(net.calls, hasLength(1), reason: 'the cache is fresh');
          expect(zone.timers.map((t) => t.period), [
            const Duration(minutes: 15),
          ]);

          // The tick comes when the cache is just under 15 minutes old: it must
          // ask anyway.
          zone.timers.single.fire();
          await pumpEventQueue();
          expect(net.calls, hasLength(2));

          s.stop();
          expect(zone.timers.single.isActive, isFalse);
          s.start(); // a resume after a pause arms a new one
          await pumpEventQueue();
          expect(zone.timers, hasLength(2));
          expect(zone.timers.where((t) => t.isActive), hasLength(1));
          s.stop();
          expect(zone.timers.where((t) => t.isActive), isEmpty);
        });
      },
    );

    group('link login', () {
      const create = {'v2/create': 'stremio_link_create.json'};
      const pending = {'v2/read': 'stremio_link_read_pending.json'};
      const ok = {'v2/read': 'stremio_link_read_ok.json'};
      const post = {..._routes, 'getUser': 'stremio_get_user.json'};

      bool isRead(Uri uri) => uri.path.contains('v2/read');
      bool isCreate(Uri uri) => uri.path.contains('v2/create');

      // Logged out, as the pane is when it offers the link.
      setUp(() => settings.stremioAuthKey = '');

      test('createLinkCode parses code, link and QR url', () async {
        final net = fake(create);

        final code = await StremioClient(get: net.call).createLinkCode();

        expect(
          net.calls.single.toString(),
          'https://link.stremio.com/api/v2/create?type=Create',
        );
        expect(
          (code.code, code.link),
          ('89G5', 'https://link.stremio.com/89G5'),
        );
        expect(code.qrcodeUrl, startsWith('https://link.stremio.com/qr?'));

        // Stremio's own refusal is a StremioError, as for any of its calls.
        final refused = StremioClient(
          get: fake({'v2/create': 'stremio_link_read_pending.json'}).call,
        );
        await expectLater(
          refused.createLinkCode(),
          throwsA(isA<StremioError>().having((e) => e.code, 'code', 101)),
        );
      });

      test('readLinkCode is null until approved, then the key', () async {
        final net = fake(pending);

        expect(await StremioClient(get: net.call).readLinkCode('89G5'), isNull);
        expect(
          net.calls.single.toString(),
          'https://link.stremio.com/api/v2/read?type=Read&code=89G5',
        );
        expect(
          await StremioClient(get: fake(ok).call).readLinkCode('89G5'),
          'KEY',
        );
      });

      test('readLinkCode lets a network or parse failure rise', () async {
        final offline = StremioClient(
          get: _answering(
            (uri) async => throw const SocketException('offline'),
          ),
        );
        final odd = StremioClient(get: _answering((uri) async => {'oops': 1}));

        await expectLater(
          offline.readLinkCode('89G5'),
          throwsA(isA<SocketException>()),
        );
        await expectLater(
          odd.readLinkCode('89G5'),
          throwsA(isNot(isA<StremioError>())),
        );
      });

      test('userEmail reads the account email, empty when missing', () async {
        final net = fakePost(post);

        expect(
          await StremioClient(post: net.call).userEmail('KEY'),
          'alex@example.com',
        );
        final (uri, body) = net.calls.single;
        expect(uri.toString(), '$_api/getUser');
        expect(body, {'type': 'GetUser', 'authKey': 'KEY'});

        final none = fakePost({'getUser': 'stremio_link_read_ok.json'});
        expect(await StremioClient(post: none.call).userEmail('KEY'), '');
      });

      test(
        'startLink shows a code and polls every 3 s without storing anything',
        () async {
          final zone = FakeTimerZone();
          final net = fake({...create, ...pending});
          final s = source(fakePost(post).call, MemStore(), net.call);
          var heard = 0;
          s.addListener(() => heard++);

          await zone.run(s.startLink);

          expect(s.linkCode?.code, '89G5');
          expect([s.linkExpired, heard], [false, 1]);
          expect(zone.timers.single.period, const Duration(seconds: 3));

          await zone.timers.single.fireAndSettle();

          final reads = net.calls.where(isRead);
          expect(reads, hasLength(1));
          expect(reads.single.queryParameters, {
            'type': 'Read',
            'code': '89G5',
          });
          expect(settings.stremioAuthKey, '');
          expect(s.linkCode?.code, '89G5', reason: 'not approved: still there');
          expect(heard, 1, reason: 'nothing new to show');
        },
      );

      test(
        'approval stores the key and the email, refreshes and stops',
        () async {
          final zone = FakeTimerZone();
          final net = fakePost(post);
          final s = source(net.call, MemStore(), fake({...create, ...ok}).call);
          await zone.run(s.startLink);
          final timer = zone.timers.single;

          await timer.fireAndSettle();

          const account = ['KEY', 'alex@example.com'];
          expect([settings.stremioAuthKey, settings.stremioEmail], account);
          final saved = await Settings.load();
          expect([saved.stremioAuthKey, saved.stremioEmail], account);
          expect(s.linkCode, isNull);
          expect(timer.isActive, isFalse);
          expect(net.calls.map((c) => c.$1.path), [
            '/api/getUser',
            '/api/datastoreGet',
          ]);
          expect(net.calls.first.$2, {'type': 'GetUser', 'authKey': 'KEY'});
          expect(net.calls.last.$2['authKey'], 'KEY');
          expect(_ids(s.continueWatching), _row);
          expect(s.error, isNull);
        },
      );

      test('a failing getUser still logs in, with no email', () async {
        final zone = FakeTimerZone();
        final library = fakePost(_routes);
        final s = source(
          (uri, body, {headers = const {}}) => uri.path.endsWith('getUser')
              ? throw const SocketException('offline')
              : library.call(uri, body),
          MemStore(),
          fake({...create, ...ok}).call,
        );
        await zone.run(s.startLink);

        await zone.timers.single.fireAndSettle();

        expect([settings.stremioAuthKey, settings.stremioEmail], ['KEY', '']);
        final saved = await Settings.load();
        expect([saved.stremioAuthKey, saved.stremioEmail], ['KEY', '']);
        expect(s.linkCode, isNull);
        expect(zone.timers.single.isActive, isFalse);
        expect(_ids(s.continueWatching), _row);
      });

      test('a network error on a tick keeps polling', () async {
        final zone = FakeTimerZone();
        final links = fake(create);
        // What the phone's link answers to each read, in turn.
        final reads = <Future<Map<String, dynamic>> Function()>[
          () async => throw const SocketException('offline'),
          () async => fixture('stremio_link_read_pending.json'),
          () async => fixture('stremio_link_read_ok.json'),
        ];
        var asked = 0;
        final s = source(
          fakePost(post).call,
          MemStore(),
          _answering((uri) => isRead(uri) ? reads[asked++]() : links.call(uri)),
        );
        await zone.run(s.startLink);
        final timer = zone.timers.single;

        await timer.fireAndSettle();
        expect([asked, timer.isActive, s.linkCode?.code], [1, true, '89G5']);

        await timer.fireAndSettle();
        expect([asked, timer.isActive, s.linkCode?.code], [2, true, '89G5']);

        await timer.fireAndSettle();
        expect(asked, 3);
        expect(settings.stremioAuthKey, 'KEY');
        expect([s.linkCode, timer.isActive], [null, false]);
      });

      test('a new code after 100 ticks, give up after 300', () async {
        final zone = FakeTimerZone();
        final net = fake({...create, ...pending});
        final s = source(fakePost(post).call, MemStore(), net.call);
        var heard = 0;
        s.addListener(() => heard++);
        await zone.run(s.startLink);
        final timer = zone.timers.single;
        final first = s.linkCode;
        Future<void> ticks(int n) async {
          for (var i = 0; i < n; i++) {
            await timer.fireAndSettle();
          }
        }

        await ticks(99);
        expect(net.calls.where(isCreate), hasLength(1));
        expect(s.linkCode, same(first));

        await ticks(1); // 5 minutes
        expect(net.calls.where(isCreate), hasLength(2));
        final second = s.linkCode;
        expect(second, isNot(same(first)));
        expect([timer.isActive, s.linkExpired], [true, false]);
        expect(heard, 2, reason: 'the first code, and the second');

        await ticks(100); // 10 minutes: another new code
        expect(net.calls.where(isCreate), hasLength(3));
        expect(s.linkCode, isNot(same(second)));

        await ticks(99);
        expect([timer.isActive, s.linkExpired], [true, false]);
        expect(s.linkCode, isNotNull);

        await ticks(1); // 15 minutes
        expect(net.calls.where(isCreate), hasLength(3), reason: 'gave up');
        expect(
          [s.linkCode, timer.isActive, s.linkExpired],
          [null, false, true],
        );
        expect(settings.stremioAuthKey, '');

        // Trying again clears the notice, and counts from the start.
        await zone.run(s.startLink);
        expect([s.linkExpired, s.linkCode?.code], [false, '89G5']);
        expect(zone.timers, hasLength(2));
        expect(zone.timers.last.isActive, isTrue);
        await zone.timers.last.fireAndSettle();
        expect([s.linkExpired, s.linkCode?.code], [false, '89G5']);
      });

      test('a code that fails to be asked for is no wait at all', () async {
        final zone = FakeTimerZone();
        final s = source(
          fakePost(post).call,
          MemStore(),
          _answering((uri) async => throw const SocketException('offline')),
        );
        var heard = 0;
        s.addListener(() => heard++);

        await expectLater(
          zone.run(s.startLink),
          throwsA(isA<SocketException>()),
        );

        expect([s.linkCode, zone.timers, heard], [null, isEmpty, 0]);
      });

      test('a tick that finds the last ask still out does nothing', () async {
        final zone = FakeTimerZone();
        final answer = Completer<Map<String, dynamic>>();
        final links = fake(create);
        var reads = 0;
        final s = source(
          fakePost(post).call,
          MemStore(),
          _answering((uri) {
            if (!isRead(uri)) return links.call(uri);
            reads++;
            return answer.future;
          }),
        );
        await zone.run(s.startLink);
        final timer = zone.timers.single;

        timer.fire();
        timer.fire(); // the first read has no answer yet
        await pumpEventQueue();
        expect(reads, 1);

        answer.complete(fixture('stremio_link_read_pending.json'));
        await pumpEventQueue();
        await timer.fireAndSettle();
        expect(reads, 2, reason: 'the next tick asks again');
      });

      test('cancelLink drops a late answer', () async {
        final zone = FakeTimerZone();
        final answer = Completer<Map<String, dynamic>>();
        final links = fake(create);
        final net = fakePost(post);
        final s = source(
          net.call,
          MemStore(),
          _answering((uri) => isRead(uri) ? answer.future : links.call(uri)),
        );
        await zone.run(s.startLink);
        final timer = zone.timers.single;

        timer.fire(); // the read is out
        s.cancelLink();
        answer.complete(fixture('stremio_link_read_ok.json'));
        await pumpEventQueue();

        expect(settings.stremioAuthKey, '');
        expect([s.linkCode, timer.isActive], [null, false]);
        expect(net.calls, isEmpty, reason: 'no getUser, no library');
      });

      test('a new code that comes after cancelLink is dropped', () async {
        final zone = FakeTimerZone();
        final replacement = Completer<Map<String, dynamic>>();
        final links = fake({...create, ...pending});
        var creates = 0;
        final s = source(
          fakePost(post).call,
          MemStore(),
          _answering(
            (uri) => isCreate(uri) && ++creates == 2
                ? replacement.future
                : links.call(uri),
          ),
        );
        await zone.run(s.startLink);
        final timer = zone.timers.single;
        for (var i = 0; i < 99; i++) {
          await timer.fireAndSettle();
        }

        timer.fire(); // the 100th: the new code is out
        await pumpEventQueue();
        expect(creates, 2);
        s.cancelLink();
        replacement.complete(fixture('stremio_link_create.json'));
        await pumpEventQueue();

        expect(
          [s.linkCode, timer.isActive, s.linkExpired],
          [null, false, false],
        );
      });

      test('a first code that comes after stop starts no wait', () async {
        final zone = FakeTimerZone();
        final answer = Completer<Map<String, dynamic>>();
        final s = source(
          fakePost(post).call,
          MemStore(),
          _answering((uri) => answer.future),
        );
        var heard = 0;
        s.addListener(() => heard++);

        final started = zone.run(s.startLink); // the code is out
        s.stop();
        answer.complete(fixture('stremio_link_create.json'));
        await started;

        expect(s.linkCode, isNull);
        expect(zone.timers.where((t) => t.isActive), isEmpty);
        expect(heard, 0);
      });

      test('stop ends the wait, and a new link arms a new timer', () async {
        final zone = FakeTimerZone();
        final s = source(
          fakePost(post).call,
          MemStore(),
          fake({...create, ...pending}).call,
        );
        var heard = 0;
        s.addListener(() => heard++);

        s.stop(); // no link: nothing to end, nothing to tell
        s.cancelLink();
        expect(heard, 0);

        await zone.run(s.startLink);
        await zone.run(s.startLink); // a second ask keeps the one timer
        expect([zone.timers, heard], [hasLength(1), 2]);

        s.stop();
        expect(
          [s.linkCode, zone.timers.single.isActive, heard],
          [null, false, 3],
        );

        await zone.run(s.startLink);
        expect(zone.timers, hasLength(2));
        expect(zone.timers.where((t) => t.isActive), hasLength(1));
        s.cancelLink();
        expect(zone.timers.where((t) => t.isActive), isEmpty);
        expect([s.linkCode, heard], [null, 5]);
      });
    });
  });
}
