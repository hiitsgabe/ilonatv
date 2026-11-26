import 'dart:io';

import 'package:ilonatv/data/sports.dart';
import 'package:ilonatv/data/stremio.dart';
import 'package:ilonatv/data/tmdb.dart';
import 'package:ilonatv/data/weather.dart';
import 'package:ilonatv/data/youtube.dart';
import 'package:ilonatv/data/youtube_tv.dart';
import 'package:ilonatv/net.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/sources.dart';
import 'package:ilonatv/ui/content_row.dart';
import 'package:ilonatv/ui/search_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _routes = {
  'genre/movie/list': 'tmdb_genres_movie.json',
  'genre/tv/list': 'tmdb_genres_tv.json',
  'search/movie': 'tmdb_search_movie.json',
  'search/tv': 'tmdb_search_tv.json',
  'movie/top_rated': 'tmdb_trending_movie.json',
  'tv/top_rated': 'tmdb_trending_tv.json',
  'discover/movie': 'tmdb_popular_movie.json',
  'discover/tv': 'tmdb_popular_tv.json',
};

/// [net], with the genre-of-the-day list answered by its own fixture: in
/// the app it is a different list from the hidden gems, which share its path.
Fetch _genreApart(Fetch net) => (uri, {headers = const {}}) async {
  final answer = await net(uri);
  return uri.queryParameters.containsKey('with_genres')
      ? fixture('tmdb_recommendations.json')
      : answer;
};

/// A YouTube that signs anyone in.
class _Client extends YoutubeTvClient {
  _Client(Post post) : super(store: MemStore(), post: post, getText: _offline);

  @override
  Future<String> accessToken(String refreshToken) async =>
      'ACCESS:$refreshToken';
}

/// YouTube, offline: no test reaches the real one.
Future<String> _offline(Uri _, {Map<String, String> headers = const {}}) =>
    Future.error(const SocketException('offline'));

/// The screen open on [day], its field empty, with TMDB's answers from
/// [fetch] and YouTube's from [post] for [accounts].
/// The settings of the last [_open].
late Settings _settings;

Future<void> _open(
  WidgetTester tester,
  Fetch fetch, {
  Post? post,
  List<YtAccount> accounts = const [],
  DateTime? day,
  List<String> recent = const [],
}) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await Settings.load()
    ..tmdbKey = 'KEY'
    ..youtubeAccounts = accounts
    ..recentSearches = [...recent];
  _settings = settings;
  // A fresh screen each time, not the last one's state.
  await tester.pumpWidget(const SizedBox());
  final store = MemStore();
  final sources = Sources(
    weather: WeatherSource(settings, store, fetch: fake({}).call),
    tmdb: TmdbSource(settings, store, fetch: fetch, post: fakePost({}).call),
    stremio: StremioSource(
      settings,
      store,
      client: StremioClient(post: fakePost({}).call),
    ),
    youtube: YoutubeSource(settings, store, _Client(post ?? fakePost({}).call)),
    sports: SportsSource(settings, store, fetch: fake({}).call),
  );
  await tester.pumpWidget(
    MaterialApp(
      home: SearchScreen(
        settings,
        sources,
        today: () => day ?? DateTime(2026, 1, 1),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// OK on the field, [query] typed, Search on the keyboard.
Future<void> _search(
  WidgetTester tester,
  Fetch fetch,
  String query, {
  Post? post,
  List<YtAccount> accounts = const [],
}) async {
  await _open(tester, fetch, post: post, accounts: accounts);
  await tester.sendKeyEvent(LogicalKeyboardKey.select);
  await tester.pump();
  await tester.enterText(find.byType(TextField), query);
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pumpAndSettle();
}

List<String> _titles(WidgetTester tester, String row) => [
  for (final i in tester.widget<ContentRow>(find.byKey(ValueKey(row))).items)
    i.title,
];

void main() {
  testWidgets('an empty field shows the discovery rows', (tester) async {
    final net = fake(_routes);
    await _open(tester, _genreApart(net.call));

    expect(
      [
        for (final r in tester.widgetList<ContentRow>(find.byType(ContentRow)))
          r.title,
      ],
      ['Top rated', 'Hidden gems', 'Action in the spotlight'],
    );
    // Films and series in turn.
    expect(_titles(tester, 'topRated').take(3), [
      'Fight Club',
      'Breaking Bad',
      'Pulp Fiction',
    ]);
    // Dune: Part Two and The Last of Us are in Top rated already: shown once.
    expect(_titles(tester, 'hiddenGems').take(2), [
      'Avengers: Infinity War',
      'The Simpsons',
    ]);
    expect(_titles(tester, 'hiddenGems'), isNot(contains('Dune: Part Two')));
    expect(
      [
        for (final u in net.calls)
          if (u.queryParameters.containsKey('with_genres'))
            u.queryParameters['with_genres'],
      ],
      ['28'],
    );
    // Each genre list asked once.
    expect(net.calls.where((u) => u.path.contains('genre/')), hasLength(2));
    expect(
      primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(),
      isNotNull,
    );

    // Typing swaps them out; clearing brings them back.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    expect(find.byType(ContentRow), findsNothing);
    await tester.enterText(find.byType(TextField), ' ');
    await tester.pump();
    expect(find.byType(ContentRow), findsNWidgets(3));
  });

  testWidgets('a discovery row that fails leaves the others', (tester) async {
    final net = fake(_routes).call;
    await _open(
      tester,
      (uri, {headers = const {}}) async => uri.path.contains('top_rated')
          ? throw TmdbError.network
          : _genreApart(net)(uri),
    );
    expect(
      [
        for (final r in tester.widgetList<ContentRow>(find.byType(ContentRow)))
          r.title,
      ],
      ['Hidden gems', 'Action in the spotlight'],
    );
  });

  testWidgets('with a YouTube account, a third row of its videos', (
    tester,
  ) async {
    final yt = fakePost({'youtubei/v1/search': 'yt_search.json'});
    await _search(
      tester,
      fake(_routes).call,
      'lofi',
      post: yt.call,
      accounts: const [
        YtAccount(refreshToken: 'R1', name: 'Ana', pageId: 'PA'),
        YtAccount(refreshToken: 'R2', name: 'Bia'),
      ],
    );

    final row = tester.widget<ContentRow>(
      find.byKey(const ValueKey('youtube')),
    );
    expect([row.title, row.wide, row.trailerKey], ['YouTube', true, null]);
    expect(row.items.first.id, 'VIDEO000001');
    expect(yt.calls.single.$2['query'], 'lofi');
  });

  testWidgets('YouTube alone is enough when TMDB fails', (tester) async {
    await _search(
      tester,
      (_, {headers = const {}}) async => throw TmdbError.network,
      'lofi',
      post: fakePost({'youtubei/v1/search': 'yt_search.json'}).call,
      accounts: const [YtAccount(refreshToken: 'R1', name: 'Ana')],
    );
    expect(find.text('Network error'), findsNothing);
    expect(find.text('YouTube'), findsOneWidget);
  });

  testWidgets('a search is kept; kept ones are pills under the empty field, '
      'OK searches again, Clear empties them', (tester) async {
    await _search(tester, fake(_routes).call, 'runner');
    expect(_settings.recentSearches, ['runner']);

    await _open(tester, fake(_routes).call, recent: ['runner', 'derby']);
    expect(find.widgetWithText(TextButton, 'derby'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'runner'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('movies')), findsOneWidget);

    await _open(tester, fake(_routes).call, recent: ['runner']);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextButton, 'runner'), findsNothing);
    expect(_settings.recentSearches, isEmpty);
  });

  testWidgets('a query shows both rows and focus goes to the first card', (
    tester,
  ) async {
    final net = fake(_routes);
    await _search(tester, net.call, 'runner');

    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsOneWidget);
    expect(find.text('Blade Runner 2049'), findsOneWidget);
    expect(
      primaryFocus?.context?.findAncestorWidgetOfExactType<ContentRow>()?.title,
      'Movies',
    );
    expect(net.calls.last.queryParameters['query'], 'runner');
  });

  testWidgets('nothing found says so; a failure says network error', (
    tester,
  ) async {
    final genres = fake(_routes).call;
    await _search(
      tester,
      (uri, {headers = const {}}) async =>
          uri.path.contains('search/') ? {'results': []} : genres(uri),
      'zzz',
    );
    expect(find.text('No results'), findsOneWidget);
    expect(find.byType(ContentRow), findsNothing);
    expect(
      primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>(),
      isNotNull,
    );

    await _search(
      tester,
      (_, {headers = const {}}) async => throw TmdbError.network,
      'x',
    );
    expect(find.text('Network error'), findsOneWidget);
  });
}
