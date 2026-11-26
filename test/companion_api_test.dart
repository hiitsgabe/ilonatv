import 'dart:convert';
import 'dart:io';

import 'package:elimor/companion/api.dart';
import 'package:elimor/companion/state.dart';
import 'package:elimor/data/media.dart';
import 'package:elimor/data/sports.dart';
import 'package:elimor/data/stremio.dart';
import 'package:elimor/data/tmdb.dart';
import 'package:elimor/data/weather.dart';
import 'package:elimor/data/youtube.dart';
import 'package:elimor/data/youtube_tv.dart';
import 'package:elimor/net.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/sources.dart';
import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _key = 'SECRET-TMDB-KEY';
const _refresh = 'SECRET-YT-REFRESH';

const _tmdb = {
  'genre/movie/list': 'tmdb_genres_movie.json',
  'genre/tv/list': 'tmdb_genres_tv.json',
  'search/movie': 'tmdb_search_movie.json',
  'search/tv': 'tmdb_search_tv.json',
};

const _weather = {
  'v1/search': 'open_meteo_geocoding.json',
  'v1/forecast': 'open_meteo_forecast.json',
};

/// Every answer any test got, for the secrets check.
final _answers = <String>[];

late Settings _s;
late Sources _sources;
late ElimorApi _api;
final _injected = <RemoteKey>[];
final _host = <String>[];

Future<void> _setUp({Fetch? tmdb}) async {
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app.elimor/host'), (
        call,
      ) async {
        _host.add(call.method);
        return call.method == 'open' || call.method == 'launch';
      });
  _s = await Settings.load()
    ..tmdbKey = _key
    ..movieProvider = 'com.example.player'
    ..youtubeAccounts = [const YtAccount(refreshToken: _refresh, name: 'Me')];
  final store = MemStore();
  _sources = Sources(
    weather: WeatherSource(_s, store, fetch: fake(_weather).call),
    tmdb: TmdbSource(
      _s,
      store,
      fetch: tmdb ?? fake(_tmdb).call,
      post: fakePost({}).call,
    ),
    stremio: StremioSource(
      _s,
      store,
      client: StremioClient(post: fakePost({}).call),
    ),
    youtube: YoutubeSource(
      _s,
      store,
      YoutubeTvClient(
        store: store,
        post: fakePost({}).call,
        getText: (_, {headers = const {}}) =>
            Future.error(const SocketException('offline')),
      ),
    ),
    sports: SportsSource(_s, store, fetch: fake({}).call),
  );
  _injected.clear();
  _host.clear();
  _api = ElimorApi(
    _s,
    _sources,
    injectKey: (k) async {
      _injected.add(k);
      return true;
    },
  );
}

Future<(int, Object)> _call(
  String method,
  String path, {
  Map<String, String> query = const {},
  Object? body,
}) async {
  final r = await _api.handle(method, path, query, body);
  _answers.add(jsonEncode(r.$2));
  return r;
}

MediaItem _movie(int i) =>
    MediaItem(type: MediaType.movie, id: '$i', title: 'Movie $i');

const _item = {
  'type': 'movie',
  'id': '335984',
  'title': 'Blade Runner 2049',
  'imdbId': 'tt1856101',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => companionState.setInFront(true));

  test('key ok is 204 and injects RemoteKey.ok', () async {
    await _setUp();
    final (status, _) = await _call('POST', '/api/key', body: {'key': 'ok'});
    expect(status, 204);
    expect(_injected, [RemoteKey.ok]);
  });

  test('key while not in front is 409', () async {
    await _setUp();
    companionState.setInFront(false);
    final (status, body) = await _call('POST', '/api/key', body: {'key': 'ok'});
    expect(status, 409);
    expect(body, {'error': 'notInFront'});
    expect(_injected, isEmpty);
  });

  test('key refused by the window is 409', () async {
    await _setUp();
    _api = ElimorApi(_s, _sources, injectKey: (_) async => false);
    final (status, _) = await _call('POST', '/api/key', body: {'key': 'up'});
    expect(status, 409);
  });

  test('key jump is 400', () async {
    await _setUp();
    for (final body in [
      {'key': 'jump'},
      {'key': 3},
      null,
    ]) {
      final (status, _) = await _call('POST', '/api/key', body: body);
      expect(status, 400);
    }
    expect(_injected, isEmpty);
  });

  test('search returns TMDB movies and series from the fixtures; '
      'YouTube failure gives videos []', () async {
    await _setUp();
    final (status, body) = await _call(
      'GET',
      '/api/search',
      query: {'q': 'blade runner'},
    );
    expect(status, 200);
    final b = body as Map;
    expect(
      (b['movies'] as List).map((m) => (m as Map)['title']),
      contains('Blade Runner 2049'),
    );
    expect(
      (b['series'] as List).map((m) => (m as Map)['title']),
      contains('Blade Runner 2099'),
    );
    expect(b['videos'], isEmpty);
    expect((b['movies'] as List).length, lessThanOrEqualTo(20));
  });

  test('search with TMDB down still answers', () async {
    await _setUp(tmdb: fake({}).call);
    final (status, body) = await _call('GET', '/api/search', query: {'q': 'x'});
    expect(status, 200);
    expect(body, {'movies': [], 'series': [], 'videos': []});
  });

  test('search with an empty q is 400', () async {
    await _setUp();
    expect((await _call('GET', '/api/search', query: {'q': ' '})).$1, 400);
    expect((await _call('GET', '/api/search')).$1, 400);
  });

  test('rows follow shownRows and skip inputs', () async {
    await _setUp();
    _s.homeRows = [
      (key: 'trendingSeries', on: true),
      (key: 'inputs', on: true),
      (key: 'recommended', on: false),
      (key: 'trendingMovies', on: true),
    ];
    _sources.tmdb
      ..movies = [for (var i = 0; i < 25; i++) _movie(i)]
      ..series = [
        const MediaItem(type: MediaType.series, id: '9', title: 'Show'),
      ]
      ..recommended = [_movie(100)];
    final (status, body) = await _call('GET', '/api/rows');
    expect(status, 200);
    final rows = (body as List).cast<Map>();
    expect(rows.map((r) => r['key']), ['trendingSeries', 'trendingMovies']);
    expect(rows.first['title'], 'Trending · Series');
    expect((rows.first['items'] as List).single, containsPair('title', 'Show'));
    expect(rows.last['items'], hasLength(20));
  });

  test('open a movie calls openItem', () async {
    await _setUp();
    final (status, body) = await _call(
      'POST',
      '/api/open',
      body: {'item': _item},
    );
    expect(status, 200);
    expect(body, {'opened': true});
    expect(_host, contains('open'));
  });

  test('open an input is 400 and opens nothing', () async {
    await _setUp();
    for (final type in ['input', 'game']) {
      final (status, _) = await _call(
        'POST',
        '/api/open',
        body: {
          'item': {..._item, 'type': type},
        },
      );
      expect(status, 400);
    }
    expect(_host, isEmpty);
  });

  test('open with a malformed item is 400', () async {
    await _setUp();
    for (final body in [
      null,
      {'item': 'x'},
      {
        'item': {'type': 'movie'},
      },
      {
        'item': {..._item, 'type': 'nope'},
      },
    ]) {
      expect((await _call('POST', '/api/open', body: body)).$1, 400);
    }
    expect(_host, isEmpty);
  });

  test(
    'setup tmdb with a rejected key says keyBad and saves nothing',
    () async {
      await _setUp(
        tmdb: (uri, {headers = const {}}) =>
            throw const HttpStatusException(401, '{"status_code":7}'),
      );
      final (status, body) = await _call(
        'POST',
        '/api/setup/tmdb',
        body: {'key': 'WRONG', 'save': true},
      );
      expect(status, 200);
      expect(body, {'result': 'keyBad'});
      expect(_s.tmdbKey, _key);
      expect(
        (await SharedPreferences.getInstance()).getString('tmdbKey'),
        null,
      );
    },
  );

  test('setup tmdb with a good key saves it', () async {
    await _setUp();
    final (_, body) = await _call(
      'POST',
      '/api/setup/tmdb',
      body: {'key': 'GOOD', 'save': true},
    );
    expect(body, {'result': 'keyOk'});
    expect(_s.tmdbKey, 'GOOD');
    expect(
      (await SharedPreferences.getInstance()).getString('tmdbKey'),
      'GOOD',
    );
  });

  test('setup city sets city, country and saves', () async {
    await _setUp();
    final (status, places) = await _call(
      'GET',
      '/api/setup/cities',
      query: {'q': 'paris'},
    );
    expect(status, 200);
    final paris = (places as List).first as Map;
    expect(paris, containsPair('name', 'Paris'));
    expect(paris, containsPair('countryCode', 'FR'));
    expect(paris.keys, [
      'name',
      'region',
      'country',
      'lat',
      'lon',
      'countryCode',
    ]);
    final (status2, _) = await _call('POST', '/api/setup/city', body: paris);
    expect(status2, 204);
    expect(_s.weatherCity, 'Paris');
    expect(_s.weatherLat, closeTo(48.85, 0.01));
    expect(_s.country, 'FR');
    expect(
      (await SharedPreferences.getInstance()).getString('weatherCity'),
      'Paris',
    );
  });

  test('setup city with a bad place is 400', () async {
    await _setUp();
    for (final body in [
      null,
      {'name': 'Paris'},
      {
        'name': 'Paris',
        'region': '',
        'country': '',
        'lat': 'x',
        'lon': 2,
        'countryCode': 'FR',
      },
    ]) {
      expect((await _call('POST', '/api/setup/city', body: body)).$1, 400);
    }
    expect(_s.weatherCity, '');
  });

  test('an unknown route is 404', () async {
    await _setUp();
    for (final (method, path) in [('GET', '/api/nope'), ('GET', '/api/key')]) {
      final (status, body) = await _call(method, path);
      expect(status, 404);
      expect(body, {'error': 'notFound'});
    }
  });

  test('no response contains the TMDB key or a YouTube token', () async {
    await _setUp();
    await _call('GET', '/api/search', query: {'q': 'blade'});
    await _call('GET', '/api/rows');
    await _call('POST', '/api/setup/tmdb', body: {'key': 'GOOD'});
    expect(_answers, isNotEmpty);
    for (final json in _answers) {
      expect(json, isNot(contains(_key)));
      expect(json, isNot(contains(_refresh)));
      expect(json, isNot(contains('ACCESS')));
    }
  });
}
