import 'dart:io';

import 'package:elimor/data/sports.dart';
import 'package:elimor/data/stremio.dart';
import 'package:elimor/data/tmdb.dart';
import 'package:elimor/data/weather.dart';
import 'package:elimor/data/youtube.dart';
import 'package:elimor/data/youtube_tv.dart';
import 'package:elimor/net.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/sources.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// TMDB knows none of the Stremio titles, so the recommendations are the
/// popular row.
const _tmdbRoutes = {
  'genre/movie/list': 'tmdb_genres_movie.json',
  'genre/tv/list': 'tmdb_genres_tv.json',
  'trending/movie/week': 'tmdb_trending_movie.json',
  // The films out at home: the trending ones, so the row keeps them all.
  'discover/movie': 'tmdb_trending_movie.json',
  'trending/tv/week': 'tmdb_trending_tv.json',
  'find/tt': 'tmdb_find_none.json',
  'movie/popular': 'tmdb_popular_movie.json',
  'tv/popular': 'tmdb_popular_tv.json',
};

/// The request paths after `/3/`.
List<String> _paths(List<Uri> uris) => [
  for (final u in uris) u.path.substring('/3/'.length),
];

/// YouTube, offline: no test reaches the real one.
Future<String> _offline(Uri _, {Map<String, String> headers = const {}}) =>
    Future.error(const SocketException('offline'));

void main() {
  late Settings settings;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    settings = await Settings.load();
    settings
      ..tmdbKey = 'KEY'
      ..country = 'FR'
      ..weatherCity = 'Paris'
      ..weatherLat = 48.85
      ..weatherLon = 2.35
      ..fahrenheit = false
      ..youtubeAccounts = [const YtAccount(refreshToken: 'R', name: 'Me')]
      ..stremioAuthKey = 'AK';
  });

  test('Sources loads, starts and stops the five services', () async {
    // What an earlier run left behind. All five entries are young, so once
    // they are loaded no service has a reason to ask.
    final store = MemStore();
    await store.write('weather', {
      'weather': {'temp': 4.2, 'feelsLike': 1.1, 'code': 3},
      'lat': 48.85,
      'lon': 2.35,
      'fahrenheit': false,
    });
    await store.write('tmdb', {
      'movies': [
        {'type': 'movie', 'id': '550', 'title': 'Fight Club'},
      ],
      'series': [],
      'recommended': [],
      'language': 'en-US',
      // France, no Stremio app, no service mapped.
      'rows': 'FR//',
      'region': 'FR',
      'shape': 9,
    });
    // No IMDb id, so no seeds: TMDB has nothing to redo.
    await store.write('stremio', {
      'items': [
        {'type': 'movie', 'id': 'tt1', 'title': 'In Progress'},
      ],
    });
    await store.write('youtube', {
      'lists': {
        'Me': [
          {'type': 'video', 'id': 'FIXTURE0001', 'title': 'A video'},
        ],
      },
      'revoked': {},
    });
    await store.write('sports', {'games': []});
    final net = fake({});
    final account = fakePost({});
    final sources = Sources(
      weather: WeatherSource(settings, store, fetch: net.call),
      tmdb: TmdbSource(
        settings,
        store,
        fetch: net.call,
        post: fakePost({}).call,
      ),
      stremio: StremioSource(
        settings,
        store,
        client: StremioClient(post: account.call),
      ),
      youtube: YoutubeSource(
        settings,
        store,
        YoutubeTvClient(store: store, post: account.call, getText: _offline),
      ),
      sports: SportsSource(settings, store, fetch: net.call),
    );
    final zone = FakeTimerZone();

    await sources.loadCache();
    expect(sources.weather.current!.temp, 4.2);
    expect(sources.tmdb.movies.single.title, 'Fight Club');
    expect(sources.stremio.continueWatching.single.title, 'In Progress');
    expect(sources.youtube.videos.single.title, 'A video');

    await zone.run(() async {
      sources.start();
      sources.start(); // safe to call again: still one timer each
      await pumpEventQueue();
      expect(zone.timers.map((t) => t.period), [
        const Duration(minutes: 30),
        const Duration(hours: 6),
        const Duration(minutes: 15),
        const Duration(minutes: 30),
        const Duration(minutes: 5),
      ]);
      expect(net.calls, isEmpty, reason: 'all five caches are fresh');
      expect(account.calls, isEmpty, reason: 'all five caches are fresh');

      sources.stop();
      expect(zone.timers.where((t) => t.isActive), isEmpty);
    });
  });

  group('the seeds', () {
    late MemStore store;
    late ({Fetch call, List<Uri> calls}) tmdbNet;
    late Sources sources;

    setUp(() {
      store = MemStore();
      tmdbNet = fake(_tmdbRoutes);
      sources = Sources(
        weather: WeatherSource(settings, store, fetch: fake({}).call),
        tmdb: TmdbSource(
          settings,
          store,
          fetch: tmdbNet.call,
          post: fakePost({}).call,
        ),
        stremio: StremioSource(
          settings,
          store,
          client: StremioClient(
            post: fakePost({'datastoreGet': 'stremio_library.json'}).call,
          ),
        ),
        youtube: YoutubeSource(
          settings,
          store,
          YoutubeTvClient(
            store: store,
            post: fakePost({}).call,
            getText: _offline,
          ),
        ),
        sports: SportsSource(settings, store, fetch: fake({}).call),
      );
    });

    test('what Stremio has in progress seeds TMDB, and only a change redoes the row', () async {
      await store.write('tmdb', {
        'movies': [
          {'type': 'movie', 'id': '550', 'title': 'Fight Club'},
        ],
        'series': [],
        'recommended': [],
        'language': 'en-US',
        'rows': 'FR//',
        'region': 'FR',
        'shape': 9,
      });
      await sources.tmdb.loadCache();

      await sources.stremio.refresh();
      await pumpEventQueue();

      // The five seeds, asked for in order; none is known, so the popular row.
      expect(sources.tmdb.seeds, ['tt1', 'tt2', 'tt4', 'tt7', 'tt8']);
      expect(_paths(tmdbNet.calls), [
        'find/tt1',
        'find/tt2',
        'find/tt4',
        'find/tt7',
        'find/tt8',
        'genre/movie/list',
        'movie/popular',
        'genre/tv/list',
        'tv/popular',
      ]);
      expect(sources.tmdb.recommended, hasLength(20));
      expect(sources.tmdb.movies.single.title, 'Fight Club');

      // The same library again: the same seeds, and nothing is asked.
      tmdbNet.calls.clear();
      await sources.stremio.refresh(force: true);
      await pumpEventQueue();
      expect(tmdbNet.calls, isEmpty);

      // Logged out: no seeds, and the row goes back to the popular one.
      await sources.stremio.logout();
      await pumpEventQueue();
      expect(sources.tmdb.seeds, isEmpty);
      expect(_paths(tmdbNet.calls), [
        'genre/movie/list',
        'movie/popular',
        'genre/tv/list',
        'tv/popular',
      ]);
    });

    test(
      'TMDB without rows gets the seeds anyway, for its first refresh',
      () async {
        await sources.stremio.refresh();
        await pumpEventQueue();

        expect(sources.tmdb.seeds, ['tt1', 'tt2', 'tt4', 'tt7', 'tt8']);
        expect(tmdbNet.calls, isEmpty, reason: 'no rows to take titles from');

        await sources.tmdb.refresh();
        expect(_paths(tmdbNet.calls).where((p) => p.startsWith('find/')), [
          'find/tt1',
          'find/tt2',
          'find/tt4',
          'find/tt7',
          'find/tt8',
        ]);
      },
    );
  });
}
