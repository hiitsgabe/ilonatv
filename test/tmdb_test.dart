import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elimor/data/media.dart';
import 'package:elimor/data/tmdb.dart';
import 'package:elimor/net.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// Every answer the tests use. The first route whose key the path contains
/// wins, so the specific keys come before the short ones.
const _routes = {
  'trending/movie/week': 'tmdb_trending_movie.json',
  // The films out at home: the trending ones, so the row keeps them all.
  'discover/movie': 'tmdb_trending_movie.json',
  'discover/tv': 'tmdb_trending_tv.json',
  'trending/tv/week': 'tmdb_trending_tv.json',
  'movie/popular': 'tmdb_popular_movie.json',
  'tv/popular': 'tmdb_popular_tv.json',
  'genre/movie/list': 'tmdb_genres_movie.json',
  'genre/tv/list': 'tmdb_genres_tv.json',
  'external_ids': 'tmdb_external_ids.json',
  'find/tt0137523': 'tmdb_find.json',
  'find/tt0903747': 'tmdb_find_tv.json',
  'find/tt': 'tmdb_find_none.json',
  'movie/550/recommendations': 'tmdb_recommendations.json',
  'tv/1396/recommendations': 'tmdb_recommendations_tv.json',
  'search/movie': 'tmdb_search_movie.json',
  'search/tv': 'tmdb_search_tv.json',
  // A title by its id, last: the keys above name the other paths under these.
  'tv/': 'tmdb_tv_details.json',
  'movie/': 'tmdb_movie_details.json',
};

/// What one refresh with no seeds asks: the genres, the trending rows, then
/// the popular ones that fill "Recommended".
const _plainRefresh = [
  'genre/movie/list',
  'genre/tv/list',
  // The country's popular titles (JustWatch's), each as TMDB has it.
  'tv/247718',
  'tv/292741',
  'tv/213375',
  'tv/225385',
  'tv/213562',
  'tv/58957',
  'movie/940721',
  'trending/movie/week',
  'discover/movie',
  'discover/movie',
  'trending/tv/week',
  'movie/popular',
  'tv/popular',
];

const _base = 'https://api.themoviedb.org/3';
const _auth = 'api_key=KEY&language=en-US';

const _fightClub = MediaItem(
  type: MediaType.movie,
  id: '550',
  title: 'Fight Club',
);
const _breakingBad = MediaItem(
  type: MediaType.series,
  id: '1396',
  title: 'Breaking Bad',
);

/// TMDB's request paths after `/3/`.
List<String> _paths(List<Uri> uris) => [
  for (final u in uris)
    if (u.host == 'api.themoviedb.org') u.path.substring('/3/'.length),
];

List<String> _keys(List<MediaItem> items) => [for (final i in items) i.key];

/// The network: notes every request and answers it with [reply], which a test
/// swaps for one that throws to play an error.
class _Net {
  _Net(this.reply);
  Fetch reply;
  final uris = <Uri>[];

  Future<Map<String, dynamic>> call(
    Uri uri, {
    Map<String, String> headers = const {},
  }) {
    uris.add(uri);
    return reply(uri, headers: headers);
  }
}

Fetch _failing(Object error) =>
    (uri, {headers = const {}}) async => throw error;

/// JustWatch answers each request with the fixture of its operation, and
/// notes them; [failing] names an operation that fails.
({Post call, List<Map<String, dynamic>> calls}) _justWatch({String? failing}) {
  final calls = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> call(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    calls.add(body);
    final op = body['operationName'];
    if (op == failing) throw const HttpStatusException(500, '');
    final filter = (body['variables'] as Map?)?['filter'] as Map?;
    return fixture(
      op == 'GetProviders'
          ? 'jw_packages.json'
          : op == 'GetGenres'
          ? 'jw_genres.json'
          : filter?['packages'] == null && filter?['genres'] == null
          ? 'jw_popular_ca.json'
          : 'jw_popular_nfx_show.json',
    );
  }

  return (call: call, calls: calls);
}

/// [id] and [name] of each of [services], to compare.
List<(int, String)> _named(List<WatchProvider> services) => [
  for (final p in services) (p.id, p.name),
];

void main() {
  test(
    'details: a title by its id, as the rows have it, its genres named',
    () async {
      final net = fake(_routes);
      final c = TmdbClient('KEY', 'en-US', fetch: net.call);
      final series = await c.details(MediaType.series, '225385');
      expect(_paths(net.calls), ['genre/tv/list', 'tv/225385']);
      expect(series!.title, 'Black Doves (TMDB)');
      expect(series.type, MediaType.series);
      expect(series.id, '225385');
      expect(series.genre, 'Drama');
      expect(series.year, 2024);
      expect(series.overview, 'From TMDB.');
      expect(
        series.backdropUrl,
        'https://image.tmdb.org/t/p/w780/tmdb-backdrop.jpg',
      );
      expect(
        series.posterUrl,
        'https://image.tmdb.org/t/p/w342/tmdb-poster.jpg',
      );
      final film = await c.details(MediaType.movie, '940721');
      expect(film!.genre, 'Drama');
      expect(net.calls.last.path, endsWith('/movie/940721'));
    },
  );

  test('trendingAtHome: trending films out at home, in trending order, then '
      'the popular ones out at home; trendingStarted: series begun', () async {
    Map<String, dynamic> film(int id, String date) => {
      'id': id,
      'title': 'F$id',
      'release_date': date,
    };
    final asked = <Uri>[];
    Future<Map<String, dynamic>> fetch(
      Uri u, {
      Map<String, String> headers = const {},
    }) async {
      asked.add(u);
      final p = u.path;
      if (p.contains('genre')) return {'genres': []};
      if (p.contains('trending/movie')) {
        return {
          'results': [
            film(1, '2026-12-16'), // not out yet
            film(2, '2026-10-19'), // in cinemas only
            film(3, '2026-09-30'), // out at home
            film(4, ''), // no date
          ],
        };
      }
      if (p.contains('trending/tv')) {
        return {
          'results': [
            {'id': 7, 'name': 'S7', 'first_air_date': '2026-11-20'},
            {'id': 8, 'name': 'S8', 'first_air_date': '2019-01-01'},
          ],
        };
      }
      if (p.contains('discover/movie')) {
        return {
          'results': u.queryParameters['page'] == '1'
              ? [film(9, '2026-08-01'), film(3, '2026-09-30')]
              : [film(10, '2026-07-01')],
        };
      }
      throw StateError(p);
    }

    final c = TmdbClient('KEY', 'en-US', fetch: fetch);
    final today = DateTime(2026, 11, 2);
    expect(
      [for (final i in await c.trendingAtHome(today)) i.id],
      ['3', '9', '10'],
    );
    final discover = asked.firstWhere((u) => u.path.contains('discover'));
    expect(discover.queryParameters, containsPair('with_release_type', '4|5'));
    expect(
      discover.queryParameters,
      containsPair('release_date.lte', '2026-11-02'),
    );
    expect(
      discover.queryParameters,
      containsPair('release_date.gte', '2025-11-02'),
    );
    expect([for (final i in await c.trendingStarted(today)) i.id], ['8']);
  });

  group('MediaItem', () {
    const series = MediaItem(
      type: MediaType.series,
      id: 'tt0903747',
      title: 'Breaking Bad',
      year: 2008,
      genre: 'Drama',
      rating: 8.9,
      posterUrl: 'https://image.tmdb.org/t/p/w342/p.jpg',
      backdropUrl: 'https://image.tmdb.org/t/p/w1280/b.jpg',
      imdbId: 'tt0903747',
      videoId: 'tt0903747:2:5',
      subtitle: 'S2 · E5',
    );
    const video = MediaItem(
      type: MediaType.video,
      id: 'dQw4w9WgXcQ',
      title: 'A video',
    );

    test('JSON keeps every field, nulls too, and the key names the type', () {
      expect(series.toJson(), {
        'type': 'series',
        'id': 'tt0903747',
        'title': 'Breaking Bad',
        'year': 2008,
        'genre': 'Drama',
        'rating': 8.9,
        'posterUrl': 'https://image.tmdb.org/t/p/w342/p.jpg',
        'backdropUrl': 'https://image.tmdb.org/t/p/w1280/b.jpg',
        'imdbId': 'tt0903747',
        'videoId': 'tt0903747:2:5',
        'subtitle': 'S2 · E5',
      });
      expect(video.toJson(), {
        'type': 'video',
        'id': 'dQw4w9WgXcQ',
        'title': 'A video',
        'year': null,
        'genre': '',
        'rating': null,
        'posterUrl': null,
        'backdropUrl': null,
        'imdbId': null,
        'videoId': null,
        'subtitle': null,
      });
      for (final item in [series, video]) {
        // Through the text of a file, as the cache keeps it.
        final back = MediaItem.fromJson(jsonDecode(jsonEncode(item.toJson())));
        expect(back.toJson(), item.toJson());
      }
      expect(
        [series.key, video.key],
        ['series:tt0903747', 'video:dQw4w9WgXcQ'],
      );
    });

    test('a cache written by hand with whole numbers and gaps loads', () {
      final item = MediaItem.fromJson({
        'type': 'movie',
        'id': '550',
        'title': 'Fight Club',
        'year': 1999.0,
        'rating': 8,
      });
      expect([item.year, item.rating, item.genre], [1999, 8.0, '']);
      expect([item.posterUrl, item.imdbId, item.subtitle], [null, null, null]);
    });
  });

  group('TmdbClient', () {
    test('trending movies parse', () async {
      final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);
      final m = await c.trending(MediaType.movie);

      expect(m.length, 20);
      expect(
        [
          m.first.type,
          m.first.id,
          m.first.title,
          m.first.year,
          m.first.genre,
          m.first.rating,
        ],
        [MediaType.movie, '550', 'Fight Club', 1999, 'Drama', 8.4],
      );
      expect(
        m.first.posterUrl,
        'https://image.tmdb.org/t/p/w342/pB8BM7pdSp6B6Ih7QZ4DrQ3PmJK.jpg',
      );
      expect(
        m.first.backdropUrl,
        startsWith('https://image.tmdb.org/t/p/w780/'),
      );
      // TMDB has nothing to say about these; the sources fill them in.
      expect(
        [m.first.imdbId, m.first.videoId, m.first.subtitle],
        [null, null, null],
      );
    });

    test('a missing piece leaves an empty field, not a broken item', () async {
      final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);
      final byId = {for (final m in await c.trending(MediaType.movie)) m.id: m};

      // Of the genres [53, 80] TMDB gave, the list knows neither: empty, not
      // null. Of [12, 18, 878] it knows one, the second, and that one counts.
      expect(byId['680']!.genre, '');
      expect(byId['157336']!.genre, 'Drama');
      // A null path is a null address, whichever of the two it is.
      expect(byId['9000001']!.posterUrl, isNull);
      expect(byId['9000001']!.backdropUrl, isNotNull);
      expect(byId['9000002']!.posterUrl, isNotNull);
      expect(byId['9000002']!.backdropUrl, isNull);
      // 7.04 rounds to one decimal.
      expect(byId['9000002']!.rating, 7.0);
      // Not released: an empty date, no votes, no genres.
      final unreleased = byId['9000003']!;
      expect(
        [unreleased.year, unreleased.rating, unreleased.genre],
        [null, null, ''],
      );
    });

    test('trending series use name, first_air_date and the series genres', () async {
      final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);
      final s = await c.trending(MediaType.series);

      expect(s.length, 20);
      expect(
        [
          s.first.type,
          s.first.id,
          s.first.title,
          s.first.year,
          s.first.genre,
          s.first.rating,
        ],
        [MediaType.series, '1396', 'Breaking Bad', 2008, 'Drama', 8.9],
      );
      expect(s.first.key, 'series:1396');
      // Money Heist: [80, 18]. Crime is in the series list, not the movie one.
      expect(s.firstWhere((i) => i.id == '71446').genre, 'Crime');
    });

    test(
      'popular and recommendations take their type from the endpoint',
      () async {
        final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);
        final movies = await c.popular(MediaType.movie);
        final series = await c.popular(MediaType.series);

        expect([movies.length, series.length], [20, 20]);
        expect(movies.map((m) => m.type).toSet(), {MediaType.movie});
        expect(series.map((m) => m.type).toSet(), {MediaType.series});
        expect(
          [movies.first.key, movies.first.title],
          ['movie:693134', 'Dune: Part Two'],
        );
        expect(
          [series.first.key, series.first.title],
          ['series:100088', 'The Last of Us'],
        );

        final ofMovie = await c.recommendations(_fightClub);
        expect([ofMovie.length, ofMovie.first.key], [20, 'movie:807']);
        final ofSeries = await c.recommendations(_breakingBad);
        expect([ofSeries.length, ofSeries.first.key], [20, 'series:60059']);
      },
    );

    test(
      'media_type wins over the endpoint; an item with no id is skipped',
      () async {
        final c = TmdbClient(
          'KEY',
          'en-US',
          fetch: (uri, {headers = const {}}) async => uri.path.contains('genre')
              ? {'genres': []}
              : {
                  'results': [
                    {
                      'id': 1,
                      'title': 'A film in a list of series',
                      'media_type': 'movie',
                    },
                    {'title': 'No id at all'},
                    {'id': 2, 'name': 'A show'},
                  ],
                },
        );
        final items = await c.popular(MediaType.series);

        expect(_keys(items), ['movie:1', 'series:2']);
        expect(items.first.title, 'A film in a list of series');
        // Everything else was absent, and nothing broke.
        expect(
          [
            items.last.year,
            items.last.rating,
            items.last.posterUrl,
            items.last.genre,
          ],
          [null, null, null, ''],
        );
      },
    );

    test(
      'every request is the documented one, with api_key and language',
      () async {
        final net = fake(_routes);
        final c = TmdbClient('KEY', 'en-US', fetch: net.call);

        await c.trending(MediaType.movie);
        await c.trending(MediaType.series);
        await c.popular(MediaType.movie);
        await c.popular(MediaType.series);
        await c.recommendations(_fightClub);
        await c.recommendations(_breakingBad);
        await c.imdbId(_fightClub);
        await c.imdbId(_breakingBad);
        await c.findByImdb('tt0137523');

        // Each genre list is asked for once, however many rows use it.
        expect(
          [for (final u in net.calls) '$u'],
          [
            '$_base/genre/movie/list?$_auth',
            '$_base/trending/movie/week?$_auth',
            '$_base/genre/tv/list?$_auth',
            '$_base/trending/tv/week?$_auth',
            '$_base/movie/popular?$_auth',
            '$_base/tv/popular?$_auth',
            '$_base/movie/550/recommendations?$_auth',
            '$_base/tv/1396/recommendations?$_auth',
            '$_base/movie/550/external_ids?$_auth',
            '$_base/tv/1396/external_ids?$_auth',
            '$_base/find/tt0137523?external_source=imdb_id&$_auth',
          ],
        );

        // The language is the one the client was made with.
        final pt = fake(_routes);
        await TmdbClient(
          'KEY',
          'pt-BR',
          fetch: pt.call,
        ).genres(MediaType.movie);
        expect(pt.calls.single.queryParameters, {
          'api_key': 'KEY',
          'language': 'pt-BR',
        });
      },
    );

    test(
      'imdbId reads external_ids and findByImdb picks movie or tv',
      () async {
        final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);

        expect(await c.imdbId(_fightClub), 'tt0137523');

        final movie = (await c.findByImdb('tt0137523'))!;
        expect(
          [movie.type, movie.id, movie.title, movie.year, movie.genre],
          [MediaType.movie, '550', 'Fight Club', 1999, 'Drama'],
        );
        final series = (await c.findByImdb('tt0903747'))!;
        expect(
          [series.type, series.id, series.title, series.year, series.genre],
          [MediaType.series, '1396', 'Breaking Bad', 2008, 'Drama'],
        );
        expect(await c.findByImdb('tt0000001'), isNull);

        // Should TMDB have both under one id, the film comes first.
        final both = TmdbClient(
          'KEY',
          'en-US',
          fetch: (uri, {headers = const {}}) async => uri.path.contains('genre')
              ? {'genres': []}
              : {
                  'movie_results': [
                    {'id': 1, 'title': 'A film'},
                  ],
                  'tv_results': [
                    {'id': 2, 'name': 'A show'},
                  ],
                },
        );
        expect((await both.findByImdb('tt1'))!.key, 'movie:1');
      },
    );

    test('an IMDb id TMDB does not have is null', () async {
      for (final imdb in <Object?>[null, '']) {
        final c = TmdbClient(
          'KEY',
          'en-US',
          fetch: (uri, {headers = const {}}) async => {
            'id': 550,
            'imdb_id': imdb,
          },
        );
        expect(await c.imdbId(_fightClub), isNull, reason: '$imdb');
      }
    });

    test('search asks search/movie and search/tv with the query', () async {
      final net = fake(_routes);
      final c = TmdbClient('KEY', 'en-US', fetch: net.call);
      final movies = await c.search(MediaType.movie, 'runner');
      final series = await c.search(MediaType.series, 'blade runner');

      expect(_keys(movies), ['movie:335984', 'movie:78']);
      expect(movies.first.genre, 'Drama');
      expect(_keys(series), ['series:210865']);
      expect(series.first.title, 'Blade Runner 2099');
      final asked = {
        for (final u in net.calls)
          if (u.path.contains('search/')) u.path: u.queryParameters,
      };
      expect(asked, {
        '/3/search/movie': {
          'query': 'runner',
          'include_adult': 'false',
          'api_key': 'KEY',
          'language': 'en-US',
        },
        '/3/search/tv': {
          'query': 'blade runner',
          'include_adult': 'false',
          'api_key': 'KEY',
          'language': 'en-US',
        },
      });
    });

    test('the discovery lists ask top_rated and discover', () async {
      final net = fake({
        'genre/': 'tmdb_genres_movie.json',
        '': 'tmdb_search_movie.json',
      });
      final c = TmdbClient('KEY', 'en-US', fetch: net.call);
      expect(_keys(await c.topRated(MediaType.movie)), [
        'movie:335984',
        'movie:78',
      ]);
      await c.topRated(MediaType.series);
      await c.hiddenGems(MediaType.series);
      await c.discoverGenre(MediaType.movie, 28);
      expect(
        [
          for (final u in net.calls)
            if (!u.path.contains('genre/')) '$u'.substring(_base.length),
        ],
        [
          '/movie/top_rated?$_auth',
          '/tv/top_rated?$_auth',
          '/discover/tv?vote_average.gte=7.5&vote_count.gte=200'
              '&vote_count.lte=2000&sort_by=vote_average.desc&$_auth',
          '/discover/movie?with_genres=28&sort_by=popularity.desc&$_auth',
        ],
      );
    });

    test('the genre of the day goes by the day of the year', () async {
      final c = TmdbClient('KEY', 'en-US', fetch: fake(_routes).call);
      // Ids 18 Drama, 28 Action, 35 Comedy; day 1 picks the second.
      expect(await c.genreOfTheDay(DateTime(2026, 1, 1)), (28, 'Action'));
      expect(await c.genreOfTheDay(DateTime(2026, 1, 1, 23, 59)), (
        28,
        'Action',
      ));
      expect(await c.genreOfTheDay(DateTime(2026, 1, 2)), (35, 'Comedy'));
      expect(await c.genreOfTheDay(DateTime(2026, 1, 3)), (18, 'Drama'));
      // Day 305.
      expect(await c.genreOfTheDay(DateTime(2026, 11, 1)), (35, 'Comedy'));

      final none = TmdbClient(
        'KEY',
        'en-US',
        fetch: (uri, {headers = const {}}) async => {'genres': []},
      );
      expect(await none.genreOfTheDay(DateTime(2026, 1, 1)), isNull);
    });

    test('trailer prefers a YouTube Trailer, then a Teaser, else null', () async {
      final net = fake({'movie/550/videos': 'tmdb_videos.json'});
      final c = TmdbClient('KEY', 'en-US', fetch: net.call);
      expect(await c.trailer(_fightClub), 'TRAILER');
      expect(
        net.calls.single.toString(),
        '$_base/movie/550/videos?include_video_language=en%2Cen%2Cnull&$_auth',
      );

      final all = fixture('tmdb_videos.json')['results'] as List;
      TmdbClient only(bool Function(Map) keep) => TmdbClient(
        'KEY',
        'en-US',
        fetch: (uri, {headers = const {}}) async => {
          'results': [
            for (final Map v in all)
              if (keep(v)) v,
          ],
        },
      );
      expect(
        await only((v) => v['key'] != 'TRAILER').trailer(_fightClub),
        'TEASER',
      );
      expect(
        await only((v) => v['site'] == 'Vimeo').trailer(_fightClub),
        isNull,
      );

      final tv = fake({'tv/1396/videos': 'tmdb_videos.json'});
      await TmdbClient('KEY', 'en-US', fetch: tv.call).trailer(_breakingBad);
      expect(tv.calls.single.path, '/3/tv/1396/videos');

      // In Portuguese: Portuguese videos are asked for too, and a Portuguese
      // trailer beats an English one listed before it.
      final pt = TmdbClient(
        'KEY',
        'pt-BR',
        fetch: (uri, {headers = const {}}) async {
          expect(uri.queryParameters['include_video_language'], 'pt,en,null');
          return {
            'results': [
              ...all,
              {
                'iso_639_1': 'pt',
                'key': 'PT_TRAILER',
                'site': 'YouTube',
                'type': 'Trailer',
              },
            ],
          };
        },
      );
      expect(await pt.trailer(_fightClub), 'PT_TRAILER');
    });

    test(
      'a failed call is thrown as a TmdbError, whichever call it is',
      () async {
        for (final (error, mapped) in <(Object, TmdbError)>[
          (
            const HttpStatusException(401, '{"status_code":7}'),
            TmdbError.badKey,
          ),
          (const HttpStatusException(404, 'gone'), TmdbError.network),
          (const HttpStatusException(500, 'oops'), TmdbError.network),
          (const SocketException('offline'), TmdbError.network),
          (TimeoutException('slow'), TmdbError.network),
          (const FormatException('html'), TmdbError.network),
          (const HandshakeException('tls'), TmdbError.network),
        ]) {
          // Some calls ask for the genres first: let those arrive, so that each
          // call gets as far as its own request.
          final afterGenres = TmdbClient(
            'KEY',
            'en-US',
            fetch: (uri, {headers = const {}}) async =>
                uri.path.contains('genre') ? {'genres': []} : throw error,
          );
          final nothing = TmdbClient('KEY', 'en-US', fetch: _failing(error));
          for (final call in <Future<Object?> Function()>[
            () => nothing.genres(MediaType.movie),
            () => afterGenres.trending(MediaType.movie),
            () => afterGenres.popular(MediaType.series),
            () => afterGenres.recommendations(_fightClub),
            () => afterGenres.imdbId(_fightClub),
            () => afterGenres.findByImdb('tt0137523'),
            () => afterGenres.trailer(_fightClub),
          ]) {
            await expectLater(call(), throwsA(mapped), reason: '$error');
          }
        }
      },
    );
  });

  group('TmdbSource', () {
    late Directory dir;
    late Settings settings;
    late Store store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      settings
        ..tmdbKey = 'KEY'
        ..country = 'CA';
      dir = await Directory.systemTemp.createTemp('elimor');
      store = Store(dir);
    });
    tearDown(() => dir.delete(recursive: true));

    const netflix = WatchProvider(8, 'Netflix', null, key: 'nfx');
    const apple = WatchProvider(350, 'Apple TV', null, key: 'atp');

    TmdbSource source(Fetch fetch, {Post? post, Store? on}) => TmdbSource(
      settings,
      on ?? store,
      fetch: fetch,
      post: post ?? _justWatch().call,
    );

    test('refresh keeps the region\'s services in the cache, and loadCache '
        'reads them back for the same region only', () async {
      final net = fake(_routes);
      final s = source(net.call);
      await s.refresh();
      expect(s.providers.map((p) => p.id), [
        350,
        119,
        337,
        8,
        531,
        230,
        11,
        283,
      ]);
      expect(s.providers[3].key, 'nfx');
      // The country's popular titles, for the home's first fold, with them,
      // as TMDB has each.
      expect(s.popular, hasLength(7));
      expect(s.popular.first.title, 'Black Doves (TMDB)');
      expect(s.popular.last.title, 'Godzilla Minus One (TMDB)');
      final cached = (await store.read('tmdb'))!;
      expect((cached['providers'] as List).length, 8);
      expect((cached['popular'] as List).length, 7);
      expect(cached['region'], 'CA');

      final again = source(net.call);
      await again.loadCache();
      expect(again.providers.map((p) => p.id), [
        350,
        119,
        337,
        8,
        531,
        230,
        11,
        283,
      ]);
      expect(again.providers[3].key, 'nfx');
      expect(again.popular.map((i) => i.id), s.popular.map((i) => i.id));

      settings.country = 'BR';
      final elsewhere = source(net.call);
      await elsewhere.loadCache();
      expect(elsewhere.providers, isEmpty);
      expect(elsewhere.movies, hasLength(20), reason: 'the rows still load');
    });

    test('a fresh cache from another region does not stop a refresh', () async {
      final net = fake(_routes);
      await source(net.call).refresh();
      final asked = net.calls.length;
      final again = source(net.call);
      await again.loadCache();
      await again.refresh();
      expect(net.calls, hasLength(asked), reason: 'the cache is fresh');
      settings.country = 'BR';
      final moved = source(net.call);
      await moved.loadCache();
      expect(moved.providers, isEmpty, reason: 'CA\'s services are not BR\'s');
      await moved.refresh();
      expect(net.calls.length, greaterThan(asked));
      expect(moved.providers, hasLength(8));
    });

    test('providers fail: the rows still refresh and the list stays', () async {
      final net = fake(_routes);
      final s = source(
        net.call,
        post: _justWatch(failing: 'GetProviders').call,
      );
      await s.refresh();
      expect(s.error, isNull);
      expect(s.movies, hasLength(20));
      expect(s.providers, isEmpty);
    });

    test(
      'providerRow: TMDB once, then the store, then memory; it notifies',
      () async {
        final net = fake(_routes);
        final jw = _justWatch();
        final s = source(net.call, post: jw.call)..providers = [netflix];
        var heard = 0;
        s.addListener(() => heard++);
        expect(s.providerRowNow(MediaType.movie, service: 8), isNull);
        await s.providerRow(MediaType.movie, service: 8);
        final row = s.providerRowNow(MediaType.movie, service: 8)!;
        expect(row, hasLength(5));
        expect(heard, 1);
        expect(jw.calls, hasLength(1));
        expect(jw.calls.single['variables']['filter']['packages'], ['nfx']);
        // JustWatch's order and ids; each title's text and pictures from
        // TMDB, as on the other rows.
        expect(row.map((i) => i.id), [
          '225385',
          '291507',
          '285322',
          '126027',
          '203857',
        ]);
        expect(row.first.title, 'Black Doves (TMDB)');
        expect(
          row.first.backdropUrl,
          'https://image.tmdb.org/t/p/w780/tmdb-backdrop.jpg',
        );
        expect(row.first.overview, 'From TMDB.');
        expect(
          _paths(net.calls).where((p) => p.startsWith('tv/')),
          hasLength(5),
        );
        final asked = jw.calls.length;
        await s.providerRow(MediaType.movie, service: 8);
        expect(jw.calls, hasLength(asked), reason: 'in memory');

        // A new run over the same store: from the entry, no call while fresh.
        final later = source(net.call, post: jw.call)..providers = [netflix];
        expect(later.providerRowNow(MediaType.movie, service: 8), isNull);
        await later.providerRow(MediaType.movie, service: 8);
        expect(later.providerRowNow(MediaType.movie, service: 8), hasLength(5));
        expect(jw.calls, hasLength(asked), reason: 'the store answered');

        // Past 6 hours it asks again, showing the old row meanwhile.
        final entries = (await store.read('service_rows9'))!;
        expect(entries.keys, ['CA|en-US|movie|8|']);
        (entries['CA|en-US|movie|8|'] as Map)['at'] = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 7))
            .toIso8601String();
        await store.write('service_rows9', entries);
        final old = source(net.call, post: jw.call)..providers = [netflix];
        await old.providerRow(MediaType.movie, service: 8);
        expect(jw.calls.length, greaterThan(asked));
        expect(old.providerRowNow(MediaType.movie, service: 8), hasLength(5));

        // Another language is another row: the titles are in it.
        settings.language = 'pt';
        final before = jw.calls.length;
        final pt = source(net.call, post: jw.call)..providers = [netflix];
        await pt.providerRow(MediaType.movie, service: 8);
        expect(jw.calls.length, greaterThan(before));
        expect(jw.calls.last['variables']['language'], 'pt');
        expect(
          (await store.read('service_rows9'))!.keys,
          unorderedEquals(['CA|en-US|movie|8|', 'CA|pt-BR|movie|8|']),
        );
      },
    );

    test('a title TMDB fails on keeps what JustWatch said of it', () async {
      final net = fake(_routes);
      final s = source(
        (uri, {headers = const {}}) => uri.path.endsWith('/tv/291507')
            ? Future.error(const HttpStatusException(500, ''))
            : net.call(uri, headers: headers),
      )..providers = [netflix];
      await s.providerRow(MediaType.movie, service: 8);
      final row = s.providerRowNow(MediaType.movie, service: 8)!;
      expect(row.map((i) => i.title), [
        'Black Doves (TMDB)',
        'The Body',
        'Black Doves (TMDB)',
        'Black Doves (TMDB)',
        'Black Doves (TMDB)',
      ]);
      expect(row[1].backdropUrl, startsWith('https://images.justwatch.com/'));
    });

    test(
      'the genres come with the services, cached, in the language',
      () async {
        final net = fake(_routes);
        final jw = _justWatch();
        final s = source(net.call, post: jw.call);
        await s.refresh();
        expect(s.genres, hasLength(19));
        expect(
          (s.genres.first.code, s.genres.first.name),
          ('act', 'Action & Adventure'),
        );
        List<Map> asked() => [
          for (final b in jw.calls)
            if (b['operationName'] == 'GetGenres') b['variables'] as Map,
        ];
        expect(asked(), [
          {'language': 'en'},
        ]);
        expect(((await store.read('tmdb'))!['genres'] as List).length, 19);
        final again = source(net.call, post: jw.call);
        await again.loadCache();
        expect(again.genres.map((g) => g.code), s.genres.map((g) => g.code));
        // Another language asks again, in it.
        settings.language = 'pt';
        await again.refresh(force: true);
        expect(asked().last, {'language': 'pt'});
      },
    );

    test('a row by service and genre, or by genre alone', () async {
      final net = fake(_routes);
      final jw = _justWatch();
      final s = source(net.call, post: jw.call)..providers = [netflix];
      await s.providerRow(MediaType.movie, service: 8, genre: 'cmy');
      expect(jw.calls.last['variables']['filter'], {
        'packages': ['nfx'],
        'genres': ['cmy'],
        'objectTypes': ['MOVIE'],
      });
      expect(
        s.providerRowNow(MediaType.movie, service: 8, genre: 'cmy'),
        hasLength(5),
      );
      expect(s.providerRowNow(MediaType.movie, service: 8), isNull);
      // A genre alone needs no service in the list.
      final alone = source(net.call, post: jw.call);
      await alone.providerRow(MediaType.movie, genre: 'hrr');
      expect(jw.calls.last['variables']['filter'], {
        'genres': ['hrr'],
        'objectTypes': ['MOVIE'],
      });
      expect(alone.providerRowNow(MediaType.movie, genre: 'hrr'), hasLength(5));
      expect(
        (await store.read('service_rows9'))!.keys,
        unorderedEquals(['CA|en-US|movie|8|cmy', 'CA|en-US|movie||hrr']),
      );
    });

    test('a service the list does not have gets no row', () async {
      final jw = _justWatch();
      final s = source(fake(_routes).call, post: jw.call);
      await s.providerRow(MediaType.movie, service: 8);
      expect(jw.calls, isEmpty);
      expect(s.providerRowNow(MediaType.movie, service: 8), isNull);
    });

    test('two rows loading at once both reach the store', () async {
      final net = fake(_routes);
      final s = source(net.call)..providers = [netflix, apple];
      await Future.wait([
        s.providerRow(MediaType.movie, service: 8),
        s.providerRow(MediaType.series, service: 350),
      ]);
      expect(
        (await store.read('service_rows9'))!.keys,
        unorderedEquals(['CA|en-US|movie|8|', 'CA|en-US|tv|350|']),
      );
    });

    test('the rows are what is popular in Stremio and out, in its order, as '
        'TMDB has each', () async {
      settings
        ..movieProvider = kStremioPackage
        ..seriesProvider = kStremioPackage;
      final net = fake(_routes);
      final s = source((uri, {headers = const {}}) async {
        if (uri.host != 'v3-cinemeta.strem.io') {
          return net.call(uri, headers: headers);
        }
        return {
          'metas': uri.path.contains('/movie/')
              ? [
                  {'id': 'tt9999999', 'released': '2999-01-01T00:00:00.000Z'},
                  {'id': 'tt0137523', 'released': '1999-10-15T00:00:00.000Z'},
                  {'id': 'tt0000000'}, // no date: not out
                ]
              : [
                  {'id': 'tt0903747', 'released': '2008-01-20T00:00:00.000Z'},
                ],
        };
      });
      await s.refresh();
      expect(s.error, isNull);
      expect(s.movies.map((i) => (i.id, i.title)), [('550', 'Fight Club')]);
      expect(s.series.map((i) => i.id), ['1396']);
      expect(_paths(net.calls), isNot(contains('trending/movie/week')));
      expect(_paths(net.calls), isNot(contains('find/tt9999999')));
    });

    test('about fills a Stremio title from TMDB by its IMDb id, with its '
        'logo, once', () async {
      final net = fake(_routes);
      var asked = 0;
      final s = source((uri, {headers = const {}}) async {
        asked++;
        return uri.path.endsWith('/images')
            ? {
                'logos': [
                  {'file_path': '/logo.png', 'iso_639_1': 'en'},
                ],
              }
            : net.call(uri, headers: headers);
      });
      const watching = MediaItem(
        type: MediaType.movie,
        id: 'tt0137523',
        title: 'Fight Club',
        imdbId: 'tt0137523',
        subtitle: 'kept',
      );
      expect(s.aboutNow(watching), isNull);
      final about = await s.about(watching);
      expect(about.item.id, 'tt0137523');
      expect(about.item.subtitle, 'kept');
      expect(about.item.year, 1999);
      expect(about.item.rating, isNotNull);
      expect(about.item.overview, 'Fixture synopsis of Fight Club.');
      expect(about.logo, endsWith('/w500/logo.png'));
      expect(s.aboutNow(watching), about);
      final before = asked;
      await s.about(watching);
      expect(asked, before);

      // Not TMDB's to tell: answered at once, as it is.
      const video = MediaItem(type: MediaType.video, id: 'v', title: 'V');
      expect(s.aboutNow(video)!.item, video);
    });

    /// What the last session would have left in the cache.
    Future<void> seed() => source(fake(_routes).call).refresh();

    test(
      'a refresh asks the genres, the trending rows, then the rest',
      () async {
        final net = fake(_routes);
        final s = source(net.call);
        var heard = 0;
        s.addListener(() => heard++);

        await s.refresh();

        expect(_paths(net.calls), _plainRefresh);
        expect(
          [s.movies.length, s.series.length, s.recommended.length],
          [20, 20, 20],
        );
        expect(s.movies.first.title, 'Fight Club');
        expect(s.series.first.title, 'Breaking Bad');
        expect(s.error, isNull);
        expect(heard, 1);

        final cached = (await store.read('tmdb'))!;
        expect(
          cached.keys,
          unorderedEquals([
            'movies',
            'series',
            'recommended',
            'language',
            'rows',
            'shape',
            'providers',
            'genres',
            'popular',
            'region',
          ]),
        );
        expect(cached['language'], 'en-US');
        expect(cached['movies'], [for (final m in s.movies) m.toJson()]);
        expect(cached['series'], [for (final m in s.series) m.toJson()]);
        expect(cached['recommended'], [
          for (final m in s.recommended) m.toJson(),
        ]);
      },
    );

    test('recommendations merge: seeds first, interleaved, deduped, excluding rows, max 20', () async {
      final net = fake(_routes);
      final s = source(net.call)..seeds = ['tt0137523', 'tt0903747'];

      await s.refresh();

      // Each seed is found, then asked for its recommendations: the popular
      // rows are not touched while the seeds give something. The genres are
      // asked for once.
      expect(_paths(net.calls), [
        'genre/movie/list',
        'genre/tv/list',
        'tv/247718',
        'tv/292741',
        'tv/213375',
        'tv/225385',
        'tv/213562',
        'tv/58957',
        'movie/940721',
        'trending/movie/week',
        'discover/movie',
        'discover/movie',
        'trending/tv/week',
        'find/tt0137523',
        'movie/550/recommendations',
        'find/tt0903747',
        'tv/1396/recommendations',
      ]);

      // The recommendations of the movie (m) and of the series (s), in turn:
      // m0 s0 m1 s1 ... Se7en is in the movie list twice and The Sopranos in
      // the series list twice, and Pulp Fiction and Better Call Saul are on the
      // trending rows. The turns are taken first and the drops come after, so
      // the alternation has gaps: two series in a row where the second Se7en
      // was, two movies in a row where the second Sopranos was.
      expect(_keys(s.recommended), [
        'movie:807',
        'series:1398',
        'movie:77',
        'series:1438',
        'series:69740',
        'movie:603',
        'series:63351',
        'movie:500',
        'movie:278',
        'series:46648',
        'movie:238',
        'series:60622',
        'movie:13',
        'series:62560',
        'movie:424',
        'series:1405',
        'movie:769',
        'series:1104',
        'movie:1422',
        'series:1409',
      ]);
      // The same, as rules.
      final keys = _keys(s.recommended);
      expect(keys.length, 20);
      expect(keys.toSet().length, keys.length);
      expect(
        keys.toSet().intersection({..._keys(s.movies), ..._keys(s.series)}),
        isEmpty,
      );
    });

    test('at most five seeds are asked', () async {
      final net = fake(_routes);
      final s = source(net.call)
        ..seeds = ['tt0137523', 'tt0903747', 'tt1', 'tt2', 'tt3', 'tt4', 'tt5'];

      await s.refresh();

      expect(_paths(net.calls).where((p) => p.startsWith('find/')), [
        'find/tt0137523',
        'find/tt0903747',
        'find/tt1',
        'find/tt2',
        'find/tt3',
      ]);
    });

    /// A TMDB with no trending rows, where `ttN` is the film N and its
    /// recommendations are the films that [recs] lists under N (hand-made, an
    /// id and a title each). A seed that [recs] does not list is one TMDB does
    /// not know.
    Fetch tmdbWith(Map<int, List<int>> recs) =>
        (uri, {headers = const {}}) async {
          final p = uri.path.split('/'); // '', '3', 'find', 'tt2'
          final n = int.tryParse(p[3].replaceFirst('tt', ''));
          return switch (p[2]) {
            'genre' => {'genres': []},
            'trending' => {'results': []},
            'find' => {
              'movie_results': [
                if (recs.containsKey(n)) {'id': n, 'title': 'Seed $n'},
              ],
            },
            _ => {
              'results': [
                for (final id in recs[n] ?? const <int>[])
                  {'id': id, 'title': 'Film $id'},
              ],
            },
          };
        };

    /// [fetch] with one more way to fail: every request whose path has [part].
    Fetch failsAt(Fetch fetch, String part, Object error) =>
        (uri, {headers = const {}}) async =>
            uri.path.contains(part) ? throw error : fetch(uri);

    /// The recommended row a refresh against [fetch] makes from [seeds].
    Future<List<String>> row(Fetch fetch, List<String> seeds) async {
      final s = source(fetch)..seeds = seeds;
      await s.refresh();
      expect(s.error, isNull);
      return _keys(s.recommended);
    }

    test('the turns: a short list drops out, an empty or unknown seed counts for nothing', () async {
      // Seed 3 has nothing to recommend, seed 9 is not known to TMDB.
      final fetch = tmdbWith({
        1: [11, 12, 13],
        2: [21, 22],
        3: [],
      });
      const turns = [
        'movie:11',
        'movie:21',
        'movie:12',
        'movie:22',
        'movie:13',
      ];

      expect(await row(fetch, ['tt1', 'tt2']), turns);
      // The shorter list first does not cut the longer one short.
      expect(await row(fetch, ['tt2', 'tt1']), [
        'movie:21',
        'movie:11',
        'movie:22',
        'movie:12',
        'movie:13',
      ]);
      // Wherever they stand in the order, the row is the same.
      for (final odd in ['tt3', 'tt9']) {
        for (var at = 0; at <= 2; at++) {
          final seeds = ['tt1', 'tt2']..insert(at, odd);
          expect(await row(fetch, seeds), turns, reason: '$odd at $at');
        }
      }
    });

    test(
      'a seed that fails is skipped, and the row comes from the others',
      () async {
        final fetch = tmdbWith({
          1: [11, 12],
          2: [21],
        });
        for (final part in ['find/tt2', '/movie/2/recommendations']) {
          final broken = failsAt(fetch, part, const SocketException('offline'));
          expect(await row(broken, ['tt2', 'tt1']), [
            'movie:11',
            'movie:12',
          ], reason: part);
        }
      },
    );

    test(
      'a rejected key fails the refresh whatever the seed, and the row stays',
      () async {
        final fetch = tmdbWith({
          1: [11, 12],
          2: [21],
        });
        await row(fetch, ['tt1']); // leaves its row in the cache
        final rejected = failsAt(
          fetch,
          'find/tt2',
          const HttpStatusException(401, '{"status_code":7}'),
        );
        final s = source(rejected)..seeds = ['tt1', 'tt2'];
        await s.loadCache();

        await s.refresh(force: true);

        expect(s.error, TmdbError.badKey);
        expect(_keys(s.recommended), ['movie:11', 'movie:12']);
      },
    );

    test('recommendations fall back to popular when there are no seeds', () async {
      // No seeds at all, and a seed TMDB cannot place: the same row.
      for (final seeds in [
        <String>[],
        ['tt0000001'],
      ]) {
        final s = source(fake(_routes).call)..seeds = seeds;

        await s.refresh();

        // Popular movies (m) and series (s) in turn: m0 s0 m1 s1 ... The first
        // three of each are on the trending rows, and drop out.
        expect(_keys(s.recommended), [
          'movie:299536',
          'series:456',
          'movie:438631',
          'series:2190',
          'movie:414906',
          'series:1418',
          'movie:603',
          'series:1100',
          'movie:120',
          'series:48891',
          'movie:122',
          'series:8592',
          'movie:278',
          'series:46648',
          'movie:238',
          'series:60622',
          'movie:13',
          'series:62560',
          'movie:424',
          'series:1405',
        ], reason: '$seeds');
      }
    });

    test(
      'refreshRecommended redoes only the recommendations, from the new seeds',
      () async {
        await seed(); // no seeds yet: the popular row
        final net = fake(_routes);
        final s = source(net.call);
        await s.loadCache();
        final movies = s.movies;
        final series = s.series;
        final popularRow = _keys(s.recommended);
        var heard = 0;
        s.addListener(() => heard++);
        s.seeds = ['tt0137523', 'tt0903747'];

        await s.refreshRecommended();

        // Each seed is found and asked for its recommendations, and the genres
        // come when a find needs them. The trending and popular rows are not
        // asked again.
        expect(_paths(net.calls), [
          'find/tt0137523',
          'genre/movie/list',
          'movie/550/recommendations',
          'find/tt0903747',
          'genre/tv/list',
          'tv/1396/recommendations',
        ]);
        expect(s.movies, same(movies));
        expect(s.series, same(series));
        expect(_keys(s.recommended), isNot(popularRow));
        // The row a whole refresh makes from the same seeds.
        final whole = source(fake(_routes).call, on: MemStore())
          ..seeds = ['tt0137523', 'tt0903747'];
        await whole.refresh();
        expect(_keys(s.recommended), _keys(whole.recommended));
        expect(_keys(s.recommended).take(2), ['movie:807', 'series:1398']);
        expect([s.error, heard], [null, 1]);

        // The cache has the new row beside the same rows and language, in the
        // shape loadCache reads.
        final cached = (await store.read('tmdb'))!;
        expect(
          cached.keys,
          unorderedEquals([
            'movies',
            'series',
            'recommended',
            'language',
            'rows',
            'shape',
            'providers',
            'genres',
            'popular',
            'region',
          ]),
        );
        expect(cached['recommended'], [
          for (final m in s.recommended) m.toJson(),
        ]);
        expect(cached['movies'], [for (final m in movies) m.toJson()]);
        expect(cached['series'], [for (final m in series) m.toJson()]);
        expect(cached['language'], 'en-US');
        // And the next start shows it.
        final restarted = source(net.call);
        await restarted.loadCache();
        expect(_keys(restarted.recommended), _keys(s.recommended));
      },
    );

    test(
      'refreshRecommended does nothing without a key or without rows',
      () async {
        await seed();
        final net = fake(_routes);
        final s = source(net.call)..seeds = ['tt0137523'];

        // Nothing loaded yet: no rows to take titles from.
        await s.refreshRecommended();
        expect(s.recommended, isEmpty);
        expect(net.calls, isEmpty);

        // Rows, but no key. Not a refresh: it says nothing about the key.
        await s.loadCache();
        settings.tmdbKey = '';
        final file = File('${dir.path}/cache/tmdb.json')
          ..setLastModifiedSync(
            DateTime.now().subtract(const Duration(days: 30)),
          );
        await s.refreshRecommended();
        expect(net.calls, isEmpty);
        expect(s.error, isNull);
        expect(s.recommended, hasLength(20));
        expect(
          DateTime.now().difference(file.lastModifiedSync()),
          greaterThan(const Duration(days: 29)),
          reason: 'the cache is left alone',
        );
      },
    );

    test(
      'refreshRecommended maps failures like refresh and keeps every list',
      () async {
        await seed();
        final failures = <(Fetch, TmdbError)>[
          (
            _failing(const HttpStatusException(401, '{"status_code":7}')),
            TmdbError.badKey,
          ),
          (_failing(const SocketException('offline')), TmdbError.network),
          (_failing(const FormatException('html')), TmdbError.network),
          // A 200 that is not TMDB's answer.
          (
            (uri, {headers = const {}}) async => {'oops': true},
            TmdbError.network,
          ),
        ];

        for (final (fetch, expected) in failures) {
          final s = source(fetch)..seeds = ['tt0137523'];
          await s.loadCache();
          final before = [for (final m in s.recommended) m.toJson()];

          await s.refreshRecommended();

          expect(s.error, expected);
          expect([for (final m in s.recommended) m.toJson()], before);
          expect(
            [s.movies.length, s.series.length, s.recommended.length],
            [20, 20, 20],
          );
        }
        expect((await store.read('tmdb'))!['recommended'], hasLength(20));

        // The next good call takes the error away.
        final net = _Net(_failing(const SocketException('offline')));
        final s = source(net.call)..seeds = ['tt0137523'];
        await s.loadCache();
        await s.refreshRecommended();
        expect(s.error, TmdbError.network);
        net.reply = fake(_routes).call;
        await s.refreshRecommended();
        expect(s.error, isNull);
        expect(_keys(s.recommended).first, 'movie:807');
      },
    );

    test(
      'a cache that will not write does not fail refreshRecommended',
      () async {
        await seed();
        final s = source(fake(_routes).call, on: FullDiskStore(dir))
          ..seeds = ['tt0137523'];
        await s.loadCache();
        final popularRow = _keys(s.recommended);

        await s.refreshRecommended();

        expect(s.error, isNull);
        expect(_keys(s.recommended), isNot(popularRow));
        expect(_keys(s.recommended).first, 'movie:807');
      },
    );

    test('no key: noKey, no call, and the lists only from the cache', () async {
      settings.tmdbKey = '';
      final net = fake(_routes);
      final s = source(net.call);
      await s.refresh();
      expect(s.error, TmdbError.noKey);
      expect([s.movies, s.series, s.recommended], [isEmpty, isEmpty, isEmpty]);
      expect(net.calls, isEmpty);

      // A cache from the days there was a key still fills the rows.
      settings.tmdbKey = 'KEY';
      await seed();
      settings.tmdbKey = '';
      final again = source(net.call);
      await again.loadCache();
      await again.refresh(force: true);
      expect(again.error, TmdbError.noKey);
      expect(again.movies, hasLength(20));
      expect(net.calls, isEmpty);
    });

    test('a rejected key is badKey, and the lists stay', () async {
      await seed();
      final net = _Net(
        _failing(const HttpStatusException(401, '{"status_code":7}')),
      );
      final s = source(net.call);
      await s.loadCache();

      await s.refresh(force: true);

      expect(s.error, TmdbError.badKey);
      expect(
        [s.movies.length, s.series.length, s.recommended.length],
        [20, 20, 20],
      );
      expect(s.movies.first.title, 'Fight Club');
      expect(net.uris, hasLength(1), reason: 'the first answer says it all');
    });

    test('any other failure is network, and the lists stay', () async {
      await seed();
      for (final error in <Object>[
        const SocketException('offline'),
        TimeoutException('slow'),
        const HttpStatusException(500, 'oops'),
        const HttpStatusException(404, 'gone'),
        const FormatException('html'),
        const HandshakeException('tls'),
      ]) {
        final s = source(_Net(_failing(error)).call);
        await s.loadCache();

        await s.refresh(force: true);

        expect(s.error, TmdbError.network, reason: '$error');
        expect(s.movies, hasLength(20), reason: '$error');
      }

      // A 200 that is not TMDB's answer is no answer: not at all, or not the
      // rows, though the genres came.
      for (final answer in <Fetch>[
        (uri, {headers = const {}}) async => {'oops': true},
        (uri, {headers = const {}}) async =>
            uri.path.contains('genre') ? {'genres': []} : {'page': 1},
      ]) {
        final s = source(answer);
        await s.loadCache();
        await s.refresh(force: true);
        expect(s.error, TmdbError.network);
        expect(s.movies, hasLength(20));
      }
    });

    test('a failure halfway keeps every list as it was', () async {
      await seed();
      final fresh = fake(_routes);
      // The trending rows arrive, one item each, so a replacement would show;
      // the popular series do not.
      Future<Map<String, dynamic>> halfway(
        Uri uri, {
        Map<String, String> headers = const {},
      }) async {
        if (uri.path.contains('tv/popular')) {
          throw const SocketException('offline');
        }
        final json = await fresh.call(uri);
        if (uri.path.contains('trending')) {
          json['results'] = (json['results'] as List).take(1).toList();
        }
        return json;
      }

      final s = source(halfway);
      await s.loadCache();

      await s.refresh(force: true);

      expect(s.error, TmdbError.network);
      expect(
        [s.movies.length, s.series.length, s.recommended.length],
        [20, 20, 20],
      );
      expect((await store.read('tmdb'))!['movies'], hasLength(20));
    });

    test(
      'a restart shows the cache of any age and does not ask while it is fresh',
      () async {
        await seed();
        final net = fake(_routes);
        final s = source(net.call);
        expect(s.movies, isEmpty);

        await s.loadCache();
        expect(
          [s.movies.length, s.series.length, s.recommended.length],
          [20, 20, 20],
        );
        expect(s.movies.first.toJson()['title'], 'Fight Club');
        await s.refresh();
        expect(net.calls, isEmpty, reason: 'fresh');

        // A month old: still what the home opens with, and now it is asked.
        File('${dir.path}/cache/tmdb.json').setLastModifiedSync(
          DateTime.now().subtract(const Duration(days: 30)),
        );
        final later = source(net.call);
        await later.loadCache();
        expect(later.movies, hasLength(20));
        await later.refresh();
        expect(_paths(net.calls), _plainRefresh);
      },
    );

    test('a cache stands for 6 hours; older, from the future, or in another language, it goes', () async {
      final net = fake(_routes);
      final s = source(net.call);
      final file = File('${dir.path}/cache/tmdb.json');
      void age(Duration d) =>
          file.setLastModifiedSync(DateTime.now().subtract(d));
      final round = _plainRefresh.length;

      await s.refresh();
      expect(net.calls, hasLength(round), reason: 'no cache');
      await s.refresh();
      expect(net.calls, hasLength(round), reason: 'just written');

      age(const Duration(hours: 5, minutes: 59));
      await s.refresh();
      expect(net.calls, hasLength(round), reason: '5 hours 59 minutes old');

      age(const Duration(hours: 6, minutes: 1));
      await s.refresh();
      expect(net.calls, hasLength(2 * round), reason: '6 hours 1 minute old');
      // The same rows again still made the cache young.
      expect(
        DateTime.now().difference((await store.writtenAt('tmdb'))!),
        lessThan(const Duration(minutes: 1)),
      );

      age(const Duration(minutes: -5));
      await s.refresh();
      expect(net.calls, hasLength(3 * round), reason: 'written in the future');

      await s.refresh(force: true);
      expect(net.calls, hasLength(4 * round), reason: 'forced');

      settings.language = 'pt';
      await s.refresh();
      expect(net.calls, hasLength(5 * round), reason: 'another language');
      expect(net.calls.last.queryParameters['language'], 'pt-BR');
      expect((await store.read('tmdb'))!['language'], 'pt-BR');
      await s.refresh();
      expect(net.calls, hasLength(5 * round), reason: 'fresh in pt-BR');
    });

    test(
      'a cache this version cannot read is skipped, then replaced',
      () async {
        final good = _fightClub.toJson();
        for (final bad in <Map<String, dynamic>>[
          {'movies': 'x', 'series': [], 'recommended': [], 'language': 'en-US'},
          {
            'movies': [good],
            'series': 'x',
            'recommended': [],
            'language': 'en-US',
            'shape': 3,
          },
          {
            'movies': [good],
            'series': [],
            'recommended': [
              {'type': 'movie'},
            ],
            'language': 'en-US',
            'shape': 3,
          },
          {'series': [], 'recommended': [], 'language': 'en-US'},
        ]) {
          await store.write('tmdb', bad);
          final net = fake(_routes);
          final s = source(net.call);

          await s.loadCache();
          // All or nothing: the one good list is not shown on its own.
          expect(
            [s.movies, s.series, s.recommended],
            [isEmpty, isEmpty, isEmpty],
            reason: '$bad',
          );

          // It reads as young, but with nothing to show it is not a cache.
          await s.refresh();
          expect(net.calls, isNotEmpty, reason: '$bad');
          expect(s.movies, hasLength(20), reason: '$bad');
        }
      },
    );

    test('an answer for a key, a language or a country that was replaced is dropped, its error too', () async {
      final country = settings.country;
      for (final change in <void Function()>[
        () => settings.tmdbKey = 'NEW', // what saving another key does
        () => settings.language = 'pt', // what the language entry does
        () => settings.country = 'ZZ', // what picking a city does
      ]) {
        for (final answer in <Fetch>[
          fake(_routes).call,
          _failing(const SocketException('offline')),
        ]) {
          final gate = Completer<void>();
          final s = source((uri, {headers = const {}}) async {
            await gate.future;
            return answer(uri);
          });
          var heard = 0;
          s.addListener(() => heard++);

          final pending = s.refresh(force: true);
          change();
          gate.complete();
          await pending;
          settings
            ..tmdbKey = 'KEY'
            ..language = 'en'
            ..country = country;

          expect(
            [s.movies, s.series, s.recommended],
            [isEmpty, isEmpty, isEmpty],
          );
          expect([s.error, heard], [null, 0]);
          expect(await store.read('tmdb'), isNull);
        }
      }

      // The recommendations alone follow the same rule.
      await seed();
      final cached = await store.read('tmdb');
      final gate = Completer<void>();
      final net = fake(_routes);
      final s = source((uri, {headers = const {}}) async {
        await gate.future;
        return net.call(uri);
      })..seeds = ['tt0137523'];
      await s.loadCache();
      final row = _keys(s.recommended);

      final pending = s.refreshRecommended();
      settings.tmdbKey = 'NEW';
      gate.complete();
      await pending;

      expect(net.calls, isNotEmpty, reason: 'the answer came, too late');
      expect(_keys(s.recommended), row);
      expect(await store.read('tmdb'), cached);
    });

    test('clear forgets the rows and the three caches', () async {
      await seed();
      final s = source(
        fake({'watch/providers': 'tmdb_watch_providers.json', ..._routes}).call,
      );
      await s.loadCache();
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(await store.read('imdb_ids'), isNotNull);
      await s.providersFor(_fightClub);
      expect(await store.read('watch_providers'), isNotNull);
      var heard = 0;
      s.addListener(() => heard++);

      settings.tmdbKey = ''; // the key was saved empty
      await s.clear();

      expect([s.movies, s.series, s.recommended], [isEmpty, isEmpty, isEmpty]);
      expect([s.error, heard], [TmdbError.noKey, 1]);
      expect(await store.read('tmdb'), isNull);
      expect(await store.read('imdb_ids'), isNull);
      expect(await store.read('watch_providers'), isNull);
      await s.clear(); // nothing left to forget: fine
    });

    test('a cache that will not write does not fail a good fetch', () async {
      final s = source(fake(_routes).call, on: FullDiskStore(dir));

      await s.refresh();

      expect(s.error, isNull);
      expect(s.movies, hasLength(20));
      expect(await store.read('tmdb'), isNull);
    });

    test('listeners hear a change, not a repeat', () async {
      final net = _Net(_failing(const SocketException('offline')));
      final s = source(net.call);
      var heard = 0;
      s.addListener(() => heard++);

      await s.refresh();
      expect([s.error, heard], [TmdbError.network, 1]);
      await s.refresh();
      expect(heard, 1, reason: 'the same error again');

      net.reply = fake(_routes).call;
      await s.refresh();
      expect([s.error, heard], [null, 2]);

      settings.tmdbKey = '';
      await s.refresh();
      expect([s.error, heard], [TmdbError.noKey, 3]);
      await s.refresh();
      expect(heard, 3, reason: 'no key, still');

      // The key is typed in: the Settings screen forces a refresh.
      settings.tmdbKey = 'KEY';
      await s.refresh(force: true);
      expect([s.error, heard], [null, 4]);
    });

    test('imdbIdFor caches for 7 days', () async {
      final net = fake(_routes);
      final s = source(net.call);
      String ago(Duration d) =>
          DateTime.now().subtract(d).toUtc().toIso8601String();

      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(_paths(net.calls), ['movie/550/external_ids']);
      final entry = (await store.read('imdb_ids'))!['movie:550'] as Map;
      expect(entry['imdbId'], 'tt0137523');
      expect(
        DateTime.now().difference(DateTime.parse(entry['savedAt'] as String)),
        lessThan(const Duration(minutes: 1)),
      );

      // Six days old: still good.
      await store.write('imdb_ids', {
        'movie:550': {
          'imdbId': 'tt0137523',
          'savedAt': ago(const Duration(days: 6)),
        },
      });
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(net.calls, hasLength(1));

      // Eight days old: asked again, and the entry is renewed.
      await store.write('imdb_ids', {
        'movie:550': {
          'imdbId': 'tt0000000',
          'savedAt': ago(const Duration(days: 8)),
        },
      });
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(net.calls, hasLength(2));
      final renewed = (await store.read('imdb_ids'))!['movie:550'] as Map;
      expect(renewed['imdbId'], 'tt0137523');
      expect(
        DateTime.now().difference(DateTime.parse(renewed['savedAt'] as String)),
        lessThan(const Duration(minutes: 1)),
      );

      // Written in the future (the clock was off): not remembered either.
      await store.write('imdb_ids', {
        'movie:550': {
          'imdbId': 'tt0000000',
          'savedAt': ago(const Duration(days: -1)),
        },
      });
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(net.calls, hasLength(3));
    });

    test(
      'imdbIdFor remembers that there is none, and keeps the other entries',
      () async {
        var asked = 0;
        final s = source((uri, {headers = const {}}) async {
          asked++;
          return {'id': 1, 'imdb_id': null};
        });

        expect(await s.imdbIdFor(_fightClub), isNull);
        expect(await s.imdbIdFor(_fightClub), isNull);
        expect(asked, 1);

        await s.imdbIdFor(_breakingBad);
        expect(asked, 2);
        expect(
          (await store.read('imdb_ids'))!.keys,
          unorderedEquals(['movie:550', 'series:1396']),
        );
      },
    );

    test('imdbIdFor gives the old answer when TMDB cannot be asked', () async {
      await store.write('imdb_ids', {
        'movie:550': {
          'imdbId': 'tt0137523',
          'savedAt': DateTime.now()
              .subtract(const Duration(days: 8))
              .toUtc()
              .toIso8601String(),
        },
      });
      final net = _Net(_failing(const SocketException('offline')));
      final s = source(net.call);

      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(net.uris, hasLength(1));
      // Nothing is remembered about this one.
      expect(await s.imdbIdFor(_breakingBad), isNull);
    });

    test('imdbIdFor makes no call without a key', () async {
      settings.tmdbKey = '';
      await store.write('imdb_ids', {
        'movie:550': {
          'imdbId': 'tt0137523',
          'savedAt': DateTime.now()
              .subtract(const Duration(days: 8))
              .toUtc()
              .toIso8601String(),
        },
      });
      final net = fake(_routes);
      final s = source(net.call);

      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(await s.imdbIdFor(_breakingBad), isNull);
      expect(net.calls, isEmpty);
    });

    test('imdbIdFor needs no call for an item that carries its id', () async {
      final net = fake(_routes);
      final s = source(net.call);
      const withId = MediaItem(
        type: MediaType.movie,
        id: '550',
        title: 'Fight Club',
        imdbId: 'tt0137523',
      );

      expect(await s.imdbIdFor(withId), 'tt0137523');
      expect(net.calls, isEmpty);
      expect(await store.read('imdb_ids'), isNull);
    });

    test('imdbIdFor asks again when the entry is damaged, and survives a full disk', () async {
      final net = fake(_routes);
      final s = source(net.call);

      await store.write('imdb_ids', {'movie:550': 'junk'});
      expect(await s.imdbIdFor(_fightClub), 'tt0137523');
      expect(net.calls, hasLength(1));
      expect(
        ((await store.read('imdb_ids'))!['movie:550'] as Map)['imdbId'],
        'tt0137523',
      );

      // The answer is not lost because the cache will not take it. (The
      // fixture has one answer, Fight Club's, for every title.)
      final full = source(fake(_routes).call, on: FullDiskStore(dir));
      expect(await full.imdbIdFor(_breakingBad), 'tt0137523');
    });

    test('start arms one 6 hour timer whose tick refetches; stop cancels', () async {
      final zone = FakeTimerZone();
      final net = fake(_routes);
      final s = TmdbSource(
        settings,
        MemStore(),
        fetch: net.call,
        post: _justWatch().call,
      );
      final round = _plainRefresh.length;

      await zone.run(() async {
        s.stop(); // never started: nothing to cancel
        s.start();
        await pumpEventQueue();
        expect(net.calls, hasLength(round), reason: 'start refreshes at once');
        s.start();
        await pumpEventQueue();
        expect(net.calls, hasLength(round), reason: 'the cache is fresh');
        expect(zone.timers.map((t) => t.period), [const Duration(hours: 6)]);

        // The tick comes when the cache is just under 6 hours old: it must ask
        // anyway.
        zone.timers.single.fire();
        await pumpEventQueue();
        expect(net.calls, hasLength(2 * round));

        s.stop();
        expect(zone.timers.single.isActive, isFalse);
        s.start(); // a resume after a pause arms a new one
        await pumpEventQueue();
        expect(zone.timers, hasLength(2));
        expect(zone.timers.where((t) => t.isActive), hasLength(1));
        s.stop();
        expect(zone.timers.where((t) => t.isActive), isEmpty);
      });
    });
  });

  group('watch providers', () {
    late Settings settings;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = (await Settings.load())
        ..tmdbKey = 'KEY'
        ..country = 'US';
    });

    test('a title\'s: subscription, free, then with ads, once each; none to '
        'rent or buy; none for a country TMDB has nothing in', () async {
      final net = fake({'watch/providers': 'tmdb_watch_providers.json'});
      final client = TmdbClient('KEY', 'en-US', fetch: net.call);
      expect(_named(await client.watchProviders(_fightClub, 'US')), [
        (8, 'Netflix'),
        (9, 'Amazon Prime Video'),
        (73, 'Tubi TV'),
        (1796, 'Netflix Standard with Ads'),
      ]);
      expect(_named(await client.watchProviders(_fightClub, 'CA')), [
        (230, 'Crave'),
      ]);
      expect(await client.watchProviders(_fightClub, 'BR'), isEmpty);
      expect(
        net.calls.first.toString(),
        '$_base/movie/550/watch/providers?$_auth',
      );
      await client.watchProviders(_breakingBad, 'US');
      expect(net.calls.last.path, '/3/tv/1396/watch/providers');
    });

    test(
      'providersFor is remembered per country, asks again for another, '
      'finds a Stremio title first, and asks nothing without a key',
      () async {
        final net = fake({
          'watch/providers': 'tmdb_watch_providers.json',
          'find/tt0137523': 'tmdb_find.json',
          'genre/movie/list': 'tmdb_genres_movie.json',
        });
        final store = MemStore();
        final s = TmdbSource(
          settings,
          store,
          fetch: net.call,
          post: _justWatch().call,
        );
        expect(await s.providersFor(_fightClub), hasLength(4));
        expect(await s.providersFor(_fightClub), hasLength(4));
        expect(net.calls, hasLength(1));

        settings.country = 'CA';
        expect(_named(await s.providersFor(_fightClub)), [(230, 'Crave')]);
        expect(net.calls, hasLength(2));

        net.calls.clear();
        const watching = MediaItem(
          type: MediaType.movie,
          id: 'tt0137523',
          title: 'Fight Club',
          imdbId: 'tt0137523',
        );
        expect(_named(await s.providersFor(watching)), [(230, 'Crave')]);
        expect(
          [for (final u in net.calls) u.path],
          [
            '/3/find/tt0137523',
            '/3/genre/movie/list',
            '/3/movie/550/watch/providers',
          ],
        );

        // Without a key the remembered answer stands, and nothing new is asked.
        net.calls.clear();
        settings.tmdbKey = '';
        expect(_named(await s.providersFor(_fightClub)), [(230, 'Crave')]);
        expect(await s.providersFor(_breakingBad), isEmpty);
        expect(net.calls, isEmpty);
        const video = MediaItem(type: MediaType.video, id: 'v', title: 'V');
        expect(await s.providersFor(video), isEmpty);
      },
    );

    test('services mapped one after another: one refresh out, then one for '
        'the last', () async {
      final net = fake({..._routes, 'discover/tv': 'tmdb_trending_tv.json'});
      final gate = Completer<void>();
      final s = TmdbSource(
        settings,
        MemStore(),
        fetch: (uri, {headers = const {}}) async {
          await gate.future;
          return net.call(uri);
        },
        post: _justWatch().call,
      );
      for (final id in ['8', '9', '73']) {
        settings.serviceApps = {...settings.serviceApps, id: 'app.$id'};
        await settings.save();
      }
      gate.complete();
      await pumpEventQueue(times: 500);
      expect(
        net.calls.where((u) => u.path == '/3/genre/movie/list'),
        hasLength(2),
      );
      expect(s.movies, isNotEmpty);
    });

    test('providersFor keeps the newest answers only', () async {
      final store = MemStore();
      await store.write('watch_providers', {
        for (var i = 0; i < kProvidersKept; i++)
          'US/movie:$i': {
            'providers': [],
            'savedAt': DateTime.utc(2020, 1, 1, 0, 0, i).toIso8601String(),
          },
      });
      final net = fake({'watch/providers': 'tmdb_watch_providers.json'});
      await TmdbSource(
        settings,
        store,
        fetch: net.call,
        post: _justWatch().call,
      ).providersFor(_fightClub);
      final cache = (await store.read('watch_providers'))!;
      expect(cache, hasLength(kProvidersKept));
      expect(cache.containsKey('US/movie:0'), isFalse);
      expect(cache.containsKey('US/movie:1'), isTrue);
      expect(cache.containsKey('US/${_fightClub.key}'), isTrue);
    });

    test('the rows: Cinemeta only in Stremio mode; with services mapped, '
        'what is popular on those JustWatch lists in the country', () async {
      final net = fake({..._routes, 'catalog/': 'tmdb_find_none.json'});
      final jw = _justWatch();
      final s = TmdbSource(
        settings,
        MemStore(),
        fetch: net.call,
        post: jw.call,
      );
      bool cinemeta() => net.calls.any((u) => u.host == 'v3-cinemeta.strem.io');
      List<Object?> charts() => [
        for (final b in jw.calls)
          if (b['operationName'] == 'GetPopularTitles')
            b['variables']['filter'],
      ];

      await s.refresh();
      expect(cinemeta(), isFalse, reason: 'no Stremio app');
      expect(_paths(net.calls), _plainRefresh);

      net.calls.clear();
      jw.calls.clear();
      // 2 is the Apple TV store, which the list leaves out; 73 maps to None.
      settings.serviceApps = {'8': 'com.example.flix', '73': '', '2': 'x'};
      await s.refresh(force: true);
      expect(cinemeta(), isFalse);
      expect(charts().skip(1), [
        {
          'packages': ['nfx'],
          'objectTypes': ['MOVIE'],
        },
        {
          'packages': ['nfx'],
          'objectTypes': ['SHOW'],
        },
      ]);
      for (final b in jw.calls) {
        expect((b['variables'] as Map)['country'], anyOf(isNull, 'US'));
      }
      expect(_paths(net.calls), isNot(contains('trending/movie/week')));
      expect([s.error, s.movies.length, s.series.length], [null, 5, 5]);
      expect(s.movies.first.title, 'Black Doves (TMDB)');

      // A genre alone narrows the mapped services' row, not every service's.
      await s.providerRow(MediaType.movie, genre: 'cmy');
      expect(charts().last, {
        'packages': ['nfx'],
        'genres': ['cmy'],
        'objectTypes': ['MOVIE'],
      });

      net.calls.clear();
      settings.movieProvider = kStremioPackage;
      await s.refresh(force: true);
      expect(cinemeta(), isTrue);
    });

    test('with services mapped and JustWatch failing, the rows are TMDB\'s '
        'trending', () async {
      settings.serviceApps = {'8': 'com.example.flix'};
      final net = fake(_routes);
      final s = TmdbSource(
        settings,
        MemStore(),
        fetch: net.call,
        post: _justWatch(failing: 'GetPopularTitles').call,
      );
      await s.refresh();
      expect(_paths(net.calls), contains('trending/movie/week'));
      expect(_paths(net.calls), contains('trending/tv/week'));
      expect([s.error, s.movies.length], [null, 20]);
    });

    test('a change of country or mapping, once saved, asks the rows and the '
        'highlights again', () async {
      // Before the routes: their `movie/` would take these paths.
      final net = fake({
        'watch/providers': 'tmdb_watch_providers.json',
        '/images': 'tmdb_find_none.json',
        ..._routes,
      });
      final store = MemStore();
      final s = TmdbSource(
        settings,
        store,
        fetch: net.call,
        post: _justWatch().call,
      );
      await s.refresh();
      final about = await s.about(_fightClub);
      expect(about.providers, isEmpty, reason: 'no service mapped');
      expect((await store.read('tmdb'))!['rows'], 'US//');

      net.calls.clear();
      await settings.save(); // nothing that matters changed
      await pumpEventQueue(times: 500);
      expect(net.calls, isEmpty);
      expect(s.aboutNow(_fightClub), about);

      settings.serviceApps = {'8': 'com.example.flix'};
      await settings.save();
      await pumpEventQueue(times: 500);
      expect((await store.read('tmdb'))!['rows'], 'US/8/8');
      expect(s.aboutNow(_fightClub), isNull);
      expect((await s.about(_fightClub)).providers.first.name, 'Netflix');

      settings.country = 'CA';
      await settings.save();
      await pumpEventQueue(times: 500);
      expect((await store.read('tmdb'))!['rows'], 'CA/8/8');
    });
  });
}
