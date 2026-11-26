import 'dart:io';

import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/stremio.dart';
import 'package:ilonatv/data/tmdb.dart';
import 'package:ilonatv/host.dart';
import 'package:ilonatv/providers.dart';
import 'package:ilonatv/settings.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Stremio for titles, a YouTube app for videos.
  Future<Settings> settings() async {
    SharedPreferences.setMockInitialValues({});
    return (await Settings.load())
      ..movieProvider = kStremioPackage
      ..seriesProvider = kStremioPackage
      ..youtubeProvider = 'com.example.videos';
  }

  test('stremio uri encodes segments', () {
    expect(
      stremioUri(MediaType.series, 'tt0903747', 'tt0903747:2:5'),
      'stremio:///detail/series/tt0903747/tt0903747%3A2%3A5',
    );
    expect(
      stremioUri(MediaType.movie, 'tt0137523', null),
      'stremio:///detail/movie/tt0137523',
    );
  });

  test('youtube uris', () {
    expect(youtubeUri('dQw4w9WgXcQ'), 'vnd.youtube://dQw4w9WgXcQ');
    expect(
      youtubeWebUri('dQw4w9WgXcQ'),
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ',
    );
  });

  test('providerFor picks by type', () async {
    final s = (await settings())
      ..movieProvider = 'm'
      ..seriesProvider = 's'
      ..youtubeProvider = 'y';
    MediaItem item(MediaType type) =>
        MediaItem(type: type, id: '1', title: 'T');
    expect(providerFor(item(MediaType.movie), s), 'm');
    expect(providerFor(item(MediaType.series), s), 's');
    expect(providerFor(item(MediaType.video), s), 'y');
  });

  test(
    'openItem switches to an input by its id; a failed call is false',
    () async {
      final s = await settings();
      final tmdb = TmdbSource(
        s,
        MemStore(),
        fetch: fake({}).call,
        post: fakePost({}).call,
      );
      MethodCall? got;
      Object? answer = true;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
            call,
          ) async {
            got = call;
            if (answer case final Exception e) throw e;
            return answer;
          });
      const hdmi = MediaItem(type: MediaType.input, id: 'hw1', title: 'HDMI 1');
      expect(await openItem(hdmi, s, tmdb), isTrue);
      expect(got?.method, 'openInput');
      expect(got?.arguments, {'id': 'hw1', 'noSignal': 'No signal'});
      answer = false;
      expect(await openItem(hdmi, s, tmdb), isFalse);
      answer = PlatformException(code: 'x');
      expect(await openItem(hdmi, s, tmdb), isFalse);
    },
  );

  test('openItem stops at the first link that opens, else the app', () async {
    // With a key, so a TMDB title can get its IMDb id from TMDB. Plain pages
    // here; the first-stream play has its own test.
    final s = (await settings())
      ..tmdbKey = 'KEY'
      ..stremioAutoPlay = false;
    // Each call to the host is noted, and answered with the next of [answers].
    final calls = <String>[];
    late List<bool> answers;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
          call,
        ) async {
          final args = call.arguments as Map;
          calls.add([call.method, ?args['uri'], args['package']].join(' '));
          return answers.removeAt(0);
        });
    final net = fake({'external_ids': 'tmdb_external_ids.json'});
    final tmdb = TmdbSource(
      s,
      MemStore(),
      fetch: net.call,
      post: fakePost({}).call,
    );

    Future<List<String>> open(MediaItem item, List<bool> replies) async {
      calls.clear();
      answers = replies;
      await openItem(item, s, tmdb);
      expect(answers, isEmpty, reason: 'every reply was asked for');
      return calls;
    }

    const video = MediaItem(
      type: MediaType.video,
      id: 'dQw4w9WgXcQ',
      title: 'V',
      videoId: 'dQw4w9WgXcQ',
    );
    expect(await open(video, [true]), [
      'open vnd.youtube://dQw4w9WgXcQ com.example.videos',
    ]);
    expect(await open(video, [false, false, true]), [
      'open vnd.youtube://dQw4w9WgXcQ com.example.videos',
      'open https://www.youtube.com/watch?v=dQw4w9WgXcQ com.example.videos',
      'launch com.example.videos',
    ]);

    // A TMDB title: its IMDb id comes from TMDB.
    const fightClub = MediaItem(
      type: MediaType.movie,
      id: '550',
      title: 'Fight Club',
    );
    expect(await open(fightClub, [false, true]), [
      'open stremio:///detail/movie/tt0137523 com.stremio.one',
      'launch com.stremio.one',
    ]);
    expect(net.calls, hasLength(1));

    // A Stremio title knows its id and its episode.
    const episode = MediaItem(
      type: MediaType.series,
      id: 'tt0903747',
      title: 'Breaking Bad',
      imdbId: 'tt0903747',
      videoId: 'tt0903747:2:5',
    );
    expect(await open(episode, [true]), [
      'open stremio:///detail/series/tt0903747/tt0903747%3A2%3A5 '
          'com.stremio.one',
    ]);

    // No IMDb id to be had: Stremio opens on its home.
    final offline = TmdbSource(
      s,
      MemStore(),
      fetch: fake({}).call,
      post: fakePost({}).call,
    );
    calls.clear();
    answers = [true];
    await openItem(fightClub, s, offline);
    expect(calls, ['launch com.stremio.one']);

    // Another app that opens Stremio's links gets them too; the IMDb id is
    // remembered.
    s.movieProvider = 'com.example.stremiofork';
    expect(await open(fightClub, [true]), [
      'open stremio:///detail/movie/tt0137523 com.example.stremiofork',
    ]);
    expect(net.calls, hasLength(1));
    // With autoPlay too: the first-stream tap knows only Stremio's own build.
    s.stremioAutoPlay = true;
    expect(await open(fightClub, [false, true]), [
      'open stremio:///detail/movie/tt0137523 com.example.stremiofork',
      'launch com.example.stremiofork',
    ]);

    // No YouTube app set: any app that opens the links, and nothing to
    // launch.
    s.youtubeProvider = '';
    expect(await open(video, [false, false]), [
      'open vnd.youtube://dQw4w9WgXcQ null',
      'open https://www.youtube.com/watch?v=dQw4w9WgXcQ null',
    ]);
  });

  test('with no app for titles, the first mapped service that has the title '
      'and opens', () async {
    final s = (await settings())
      ..tmdbKey = 'KEY'
      ..movieProvider = ''
      ..country = 'US'
      ..serviceApps = {
        '8': 'com.example.flix',
        '73': 'com.example.free',
        '2': 'com.example.rent',
        '9': '',
      };
    final calls = <String>[];
    late List<bool> answers;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
          call,
        ) async {
          calls.add('${call.method} ${(call.arguments as Map)['package']}');
          return answers.removeAt(0);
        });
    final net = fake({
      'movie/550/watch/providers': 'tmdb_watch_providers.json',
      'find/tt0137523': 'tmdb_find.json',
      'genre/movie/list': 'tmdb_genres_movie.json',
    });
    final tmdb = TmdbSource(
      s,
      MemStore(),
      fetch: net.call,
      post: fakePost({}).call,
    );
    const fightClub = MediaItem(
      type: MediaType.movie,
      id: '550',
      title: 'Fight Club',
    );

    // Netflix's app is gone; Tubi's opens. Prime is set to none, and Apple TV
    // only rents it.
    answers = [false, true];
    expect(await openItem(fightClub, s, tmdb), isTrue);
    expect(calls, ['launch com.example.flix', 'launch com.example.free']);
    expect(
      watchOn(fightClub, await tmdb.providersFor(fightClub), s),
      'Netflix',
    );
    // With Netflix's app gone, the button names the one that opens.
    expect(
      watchOn(fightClub, await tmdb.providersFor(fightClub), s, [
        'com.example.free',
      ]),
      'Tubi TV',
    );

    // A title from Stremio is found by its IMDb id first.
    calls.clear();
    net.calls.clear();
    answers = [true];
    const watching = MediaItem(
      type: MediaType.movie,
      id: 'tt0137523',
      title: 'Fight Club',
      imdbId: 'tt0137523',
    );
    expect(await openItem(watching, s, tmdb), isTrue);
    expect(calls, ['launch com.example.flix']);
    expect(
      [for (final u in net.calls) u.path],
      [
        '/3/find/tt0137523',
        '/3/genre/movie/list',
        '/3/movie/550/watch/providers',
      ],
    );

    // Nothing mapped has it there: nothing opens.
    calls.clear();
    s.country = 'CA';
    expect(await openItem(fightClub, s, tmdb), isFalse);
    expect(calls, isEmpty);
    expect(watchOn(fightClub, await tmdb.providersFor(fightClub), s), isNull);

    // In Stremio mode the button names no service.
    s
      ..country = 'US'
      ..movieProvider = kStremioPackage;
    expect(watchOn(fightClub, await tmdb.providersFor(fightClub), s), isNull);
  });

  test('suggestedApp matches a service to an app label', () {
    const apps = {
      'com.example.flix': InstalledApp('com.example.flix', 'Netflix'),
      'com.example.prime': InstalledApp('com.example.prime', 'Prime Video'),
      'com.example.disney': InstalledApp('com.example.disney', 'Disney+'),
      'com.example.max': InstalledApp('com.example.max', 'Max'),
      'com.example.tv': InstalledApp('com.example.tv', 'TV'),
    };
    expect(suggestedApp('Netflix', apps), 'com.example.flix');
    expect(suggestedApp('Netflix Standard with Ads', apps), 'com.example.flix');
    expect(suggestedApp('Amazon Prime Video', apps), 'com.example.prime');
    expect(suggestedApp('Disney Plus', apps), 'com.example.disney');
    expect(suggestedApp('Max', apps), 'com.example.max');
    // Too short to be found inside another name.
    expect(suggestedApp('HBO Max', apps), isNull);
    expect(suggestedApp('Apple TV', apps), isNull);
    expect(suggestedApp('Crave', apps), isNull);
    expect(suggestedApp('+', const {}), isNull);
  });
  test('with autoPlay, a Stremio title opens at its video and plays: a film '
      'at its id, a series at its episode, else the one in progress, else '
      'the first', () async {
    final s = await settings();
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
          call,
        ) async {
          calls.add('${call.method} ${(call.arguments as Map)['uri']}');
          return true;
        });
    final tmdb = TmdbSource(
      s,
      MemStore(),
      fetch: fake({}).call,
      post: fakePost({}).call,
    );
    Future<String> open(MediaItem item) async {
      calls.clear();
      await openItem(
        item,
        s,
        tmdb,
        lastVideo: (id) => id == 'tt0121955' ? 'tt0121955:5:3' : null,
      );
      return calls.single;
    }

    expect(
      await open(
        const MediaItem(
          type: MediaType.movie,
          id: 'tt0468569',
          title: 'The Dark Knight',
          imdbId: 'tt0468569',
        ),
      ),
      'openStremioAndPlay '
      'stremio:///detail/movie/tt0468569/tt0468569?autoPlay=true',
    );
    expect(
      await open(
        const MediaItem(
          type: MediaType.series,
          id: 'tt0903747',
          title: 'Breaking Bad',
          imdbId: 'tt0903747',
          videoId: 'tt0903747:2:5',
        ),
      ),
      'openStremioAndPlay '
      'stremio:///detail/series/tt0903747/tt0903747%3A2%3A5?autoPlay=true',
    );
    expect(
      await open(
        const MediaItem(
          type: MediaType.series,
          id: '2190',
          title: 'South Park',
          imdbId: 'tt0121955',
        ),
      ),
      'openStremioAndPlay '
      'stremio:///detail/series/tt0121955/tt0121955%3A5%3A3?autoPlay=true',
    );
    expect(
      await open(
        const MediaItem(
          type: MediaType.series,
          id: '1399',
          title: 'Game of Thrones',
          imdbId: 'tt0944947',
        ),
      ),
      'openStremioAndPlay '
      'stremio:///detail/series/tt0944947/tt0944947%3A1%3A1?autoPlay=true',
    );
  });

  test(
    'trailerKeyFor asks TMDB, by IMDb id first for a Stremio title',
    () async {
      final s = (await settings())..tmdbKey = 'KEY';
      final net = fake({
        'find/tt0137523': 'tmdb_find.json',
        'find/tt': 'tmdb_find_none.json',
        'genre/movie/list': 'tmdb_genres_movie.json',
        'movie/550/videos': 'tmdb_videos.json',
      });
      final tmdb = TmdbSource(
        s,
        MemStore(),
        fetch: net.call,
        post: fakePost({}).call,
      );
      List<String> paths() => [for (final u in net.calls) u.path];

      const fightClub = MediaItem(
        type: MediaType.movie,
        id: '550',
        title: 'Fight Club',
      );
      expect(await trailerKeyFor(fightClub, tmdb), 'TRAILER');
      expect(paths(), ['/3/movie/550/videos']);

      // From Continue watching: TMDB's id comes from the IMDb one first.
      net.calls.clear();
      const stremio = MediaItem(
        type: MediaType.movie,
        id: 'tt0137523',
        title: 'Fight Club',
        imdbId: 'tt0137523',
      );
      expect(await trailerKeyFor(stremio, tmdb), 'TRAILER');
      expect(paths(), [
        '/3/find/tt0137523',
        '/3/genre/movie/list',
        '/3/movie/550/videos',
      ]);

      // A title TMDB does not know has no trailer.
      net.calls.clear();
      const unknown = MediaItem(
        type: MediaType.movie,
        id: 'tt0000001',
        title: 'Nobody',
        imdbId: 'tt0000001',
      );
      expect(await trailerKeyFor(unknown, tmdb), isNull);
      expect(paths(), ['/3/find/tt0000001']);

      // No key: no call.
      net.calls.clear();
      s.tmdbKey = '';
      expect(await trailerKeyFor(fightClub, tmdb), isNull);
      expect(net.calls, isEmpty);
    },
  );

  test('openTrailerKey tries the app link, then the web one', () async {
    final s = await settings();
    final calls = <String>[];
    late List<bool> answers;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
          call,
        ) async {
          final args = call.arguments as Map;
          calls.add([call.method, ?args['uri'], args['package']].join(' '));
          return answers.removeAt(0);
        });
    answers = [false, true];
    expect(await openTrailerKey('TRAILER', s), isTrue);
    expect(calls, [
      'open vnd.youtube://TRAILER com.example.videos',
      'open https://www.youtube.com/watch?v=TRAILER com.example.videos',
    ]);
    calls.clear();
    answers = [false, false];
    expect(await openTrailerKey('TRAILER', s), isFalse);
    expect(calls, hasLength(2));
  });

  test('the Stremio account shows only when a Stremio app is a provider', () {
    const stremio = ['com.stremio.one', 'com.stremio.tv'];
    expect(
      showStremioAccount(
        movieProvider: 'com.stremio.one',
        seriesProvider: 'x',
        stremioApps: stremio,
      ),
      isTrue,
    );
    expect(
      showStremioAccount(
        movieProvider: 'x',
        seriesProvider: 'com.stremio.tv',
        stremioApps: stremio,
      ),
      isTrue,
    );
    expect(
      showStremioAccount(
        movieProvider: 'x',
        seriesProvider: 'y',
        stremioApps: stremio,
      ),
      isFalse,
    );
    expect(
      showStremioAccount(
        movieProvider: 'com.stremio.one',
        seriesProvider: 'x',
        stremioApps: const [],
      ),
      isFalse,
    );
  });
  group('openGame', () {
    const galo = GameTeam(
      id: '7632',
      name: 'Atlético-MG',
      short: 'Atlético-MG',
      abbr: 'CAM',
    );
    const gremio = GameTeam(
      id: '6273',
      name: 'Grêmio',
      short: 'Grêmio',
      abbr: 'GRE',
    );
    const raptors = GameTeam(
      id: '28',
      name: 'Toronto Raptors',
      short: 'Raptors',
      abbr: 'TOR',
    );
    const knicks = GameTeam(
      id: '18',
      name: 'New York Knicks',
      short: 'Knicks',
      abbr: 'NY',
    );
    MediaItem item(String league, GameTeam home, GameTeam away) => MediaItem(
      type: MediaType.game,
      id: league,
      title: 'G',
      game: Game(
        league: league,
        start: DateTime.utc(2026, 11, 1, 21, 30),
        state: 'pre',
        home: home,
        away: away,
      ),
    );
    final soccer = item('soccer/bra.1', gremio, galo);
    final nba = item('basketball/nba', raptors, knicks);
    final catalog = [
      const CatalogItem('ch5', 'tv', 'Sports 5', 'Basketball'),
      const CatalogItem(
        'ev:gre-cam',
        'events',
        'GREMIO x ATLETICO MINEIRO',
        'Brasileirão',
      ),
    ];

    test('stremioGameUri: the item naming both teams, never a guess', () {
      expect(
        stremioGameUri(soccer.game!, catalog),
        'stremio:///detail/events/ev%3Agre-cam',
      );
      // Sports 5 is basketball, but it does not say whose.
      expect(stremioGameUri(nba.game!, catalog), isNull);
      // The two teams in one field: a name and a description do not add up.
      expect(
        stremioGameUri(soccer.game!, [
          const CatalogItem('x', 'tv', 'Grêmio ao vivo', 'Atlético Mineiro'),
        ]),
        isNull,
      );
      expect(
        stremioGameUri(soccer.game!, [
          const CatalogItem('x', 'tv', 'Premiere 1', 'Grêmio x Galo, 18:30'),
        ]),
        'stremio:///detail/tv/x',
      );
      // Abbreviations alone are no game.
      expect(
        stremioGameUri(nba.game!, [
          const CatalogItem('x', 'tv', 'NHL: NY @ TOR', ''),
        ]),
        isNull,
      );
      // One team is not the game.
      expect(
        stremioGameUri(soccer.game!, [
          const CatalogItem('x', 'tv', 'Grêmio x Inter', ''),
        ]),
        isNull,
      );
    });

    final calls = <String>[];
    late List<bool> answers;
    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
            call,
          ) async {
            final args = call.arguments as Map;
            calls.add([call.method, ?args['uri'], ?args['package']].join(' '));
            return answers.removeAt(0);
          });
    });
    SportsCatalogs catalogs(List<String> asked) => SportsCatalogs(
      client: StremioClient(
        post: (uri, body, {headers = const {}}) async {
          asked.add(body['authKey'] as String);
          return fixture('stremio_addon_collection.json');
        },
        get: fake({
          '/catalog/tv/': 'stremio_catalog_live.json',
          '/catalog/events/': 'stremio_catalog_events.json',
        }).call,
      ),
    );

    test('the add-on item in Stremio, else nothing', () async {
      final s = (await settings())..stremioAuthKey = 'AK';
      final asked = <String>[];
      final sports = catalogs(asked);

      answers = [true];
      expect(await openGame(soccer, s, catalogs: sports), isTrue);
      // The game's page, with its first stream played.
      expect(calls, [
        'openStremioAndPlay stremio:///detail/events/ev%3Agre-cam '
            'com.stremio.one',
      ]);
      calls.clear();
      s.stremioAutoPlay = false;
      answers = [true];
      expect(await openGame(soccer, s, catalogs: sports), isTrue);
      expect(calls, [
        'open stremio:///detail/events/ev%3Agre-cam com.stremio.one',
      ]);
      s.stremioAutoPlay = true;

      // Stremio will not open it: no other app is tried.
      calls.clear();
      answers = [false];
      expect(await openGame(soccer, s, catalogs: sports), isFalse);
      expect(calls, [
        'openStremioAndPlay stremio:///detail/events/ev%3Agre-cam '
            'com.stremio.one',
      ]);
      expect(asked, ['AK'], reason: 'the catalogs were cached');

      // Another Stremio app gets the page, with no tap.
      calls.clear();
      s.movieProvider = 'com.example.stremiofork';
      answers = [true];
      expect(await openGame(soccer, s, catalogs: sports), isTrue);
      expect(calls, [
        'open stremio:///detail/events/ev%3Agre-cam com.example.stremiofork',
      ]);

      // No Stremio app for titles: nothing to open it in.
      calls.clear();
      s
        ..movieProvider = ''
        ..seriesProvider = '';
      expect(await openGame(soccer, s, catalogs: sports), isFalse);
      expect(calls, isEmpty);
    });

    test('a game no item names opens nothing', () async {
      final s = (await settings())..stremioAuthKey = 'AK';
      expect(await openGame(nba, s, catalogs: catalogs([])), isFalse);
      expect(calls, isEmpty);
    });

    test('no account, or catalogs failing: nothing opens', () async {
      final s = await settings();
      final asked = <String>[];
      expect(await openGame(soccer, s, catalogs: catalogs(asked)), isFalse);
      expect(asked, isEmpty);
      expect(calls, isEmpty);

      s.stremioAuthKey = 'AK';
      final offline = SportsCatalogs(
        client: StremioClient(
          post: (uri, body, {headers = const {}}) async =>
              throw const SocketException('offline'),
        ),
      );
      expect(await openGame(soccer, s, catalogs: offline), isFalse);
      expect(calls, isEmpty);
    });
  });
}
