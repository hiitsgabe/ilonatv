import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:elimor/companion/pairing.dart';
import 'package:elimor/data/inputs.dart';
import 'package:elimor/data/media.dart';
import 'package:elimor/data/sports.dart';
import 'package:elimor/data/stremio.dart';
import 'package:elimor/data/tmdb.dart';
import 'package:elimor/data/weather.dart';
import 'package:elimor/data/youtube.dart';
import 'package:elimor/data/youtube_tv.dart';
import 'package:elimor/i18n.dart';
import 'package:elimor/net.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/host.dart';
import 'package:elimor/sources.dart';
import 'package:elimor/ui/app_row.dart';
import 'package:elimor/ui/backdrop.dart';
import 'package:elimor/ui/content_row.dart';
import 'package:elimor/ui/glass.dart';
import 'package:elimor/ui/home_screen.dart';
import 'package:elimor/ui/tile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// A video app on the dock.
const _videos = 'com.example.videos';

/// The home on a Fire TV's screen with a dock of four tiles, no TMDB key
/// (unless [tmdbKey]), one film in the trending movies row and one series in
/// the next; [games] in the games row before them, and [inputs] (as
/// `tvInputs` answers) in the first row. No input opens. TMDB answers with
/// [tmdb] (nothing by default), knows the services [providers], and the rows
/// have [rowProviders] chosen. The settings come back.
Future<Settings> _open(
  WidgetTester tester, {
  List<MediaItem> games = const [],
  List<Map<String, Object?>> inputs = const [],
  String tmdbKey = '',
  Fetch? tmdb,
  Post? justWatch,
  List<WatchProvider> providers = const [],
  List<Genre> genres = const [],
  List<MediaItem> popular = const [],
  Map<String, int> rowProviders = const {},
  Map<String, String> rowGenres = const {},
}) async {
  // The Fire TV's screen, in logical pixels.
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('app.elimor/host'),
        (call) async => switch (call.method) {
          'listApps' => [
            for (final p in [_videos, 'com.example.tv', kStremioPackage])
              {'package': p, 'label': p},
          ],
          'tvInputs' => inputs,
          'openInput' => false,
          _ => null,
        },
      );
  SharedPreferences.setMockInitialValues({
    'tiles': jsonEncode([
      const AppTile(_videos, 'youtube').toJson(),
      const AppTile('com.example.tv', 'tv').toJson(),
      const AppTile(kStremioPackage, 'app').toJson(),
      const AppTile('elimor:apps', 'apps').toJson(),
    ]),
  });
  final settings = await Settings.load()
    ..tmdbKey = tmdbKey
    ..rowProviders = Map.of(rowProviders)
    ..rowGenres = Map.of(rowGenres);
  final store = MemStore();
  final sources = Sources(
    weather: WeatherSource(settings, store, fetch: fake({}).call),
    tmdb: TmdbSource(
      settings,
      store,
      fetch: tmdb ?? fake({}).call,
      post: justWatch ?? fakePost({}).call,
    ),
    stremio: StremioSource(
      settings,
      store,
      client: StremioClient(post: fakePost({}).call),
    ),
    youtube: YoutubeSource(
      settings,
      store,
      YoutubeTvClient(
        store: MemStore(),
        post: fakePost({}).call,
        getText: (_, {headers = const {}}) =>
            Future.error(const SocketException('offline')),
      ),
    ),
    sports: SportsSource(settings, store, fetch: fake({}).call),
  );
  sources.sports.games = games;
  sources.tmdb
    ..movies = const [MediaItem(type: MediaType.movie, id: '1', title: 'Film')]
    ..series = const [MediaItem(type: MediaType.series, id: '2', title: 'Show')]
    ..providers = providers
    ..genres = genres
    ..popular = popular;
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(settings, sources, pairing: Pairing(settings)),
    ),
  );
  await tester.pumpAndSettle();
  return settings;
}

/// TMDB's genres, which a service's row names its titles' genres with.
const _serviceRoutes = {'genre/movie/list': 'tmdb_genres_movie.json'};
const _netflix = [WatchProvider(8, 'Netflix', null, key: 'nfx')];
const _netflixRow = {'graphql': 'jw_popular_nfx_show.json'};
const _comedy = [Genre('cmy', 'Comedy'), Genre('hrr', 'Horror')];

bool _focused(WidgetTester tester, IconData icon) =>
    Focus.of(tester.element(find.byIcon(icon))).hasPrimaryFocus;

bool _lastTileFocused(WidgetTester tester) => Focus.of(
  tester.element(
    find.descendant(
      of: find.byType(Tile).last,
      matching: find.byType(FocusLift),
    ),
  ),
).hasPrimaryFocus;

/// Watch's fill: white while it is the white one, the theme's otherwise.
Color? _watchFill(WidgetTester tester) => tester
    .widget<TextButton>(
      find.ancestor(
        of: find.text(t('watch')),
        matching: find.byType(TextButton),
      ),
    )
    .style
    ?.backgroundColor
    ?.resolve({});

/// The title of the row the focused card is in.
String? _rowWithFocus() =>
    primaryFocus?.context?.findAncestorWidgetOfExactType<ContentRow>()?.title;

double _hint(WidgetTester tester) =>
    tester.widget<AnimatedOpacity>(find.byKey(const ValueKey('more'))).opacity;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('one row on screen: the apps with a hint, then the content row', (
    tester,
  ) async {
    await _open(tester);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final row = find.text(t('trendingMovies'));
    expect(row, findsOneWidget);
    expect(tester.getRect(row).top, greaterThanOrEqualTo(screen.height));
    expect(_hint(tester), 1);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(tester.getRect(row).bottom, lessThanOrEqualTo(screen.height));
    // The dock has gone above the clip under the highlight.
    expect(
      tester.getRect(find.byType(AppRow)).bottom,
      lessThanOrEqualTo(0.62 * screen.height - 8),
    );
    expect(_hint(tester), 0);

    // The next row up pushes this one above the clip too.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(
      tester.getRect(find.text(t('trendingSeries'))).bottom,
      lessThanOrEqualTo(screen.height),
    );
    final first = find.ancestor(of: row, matching: find.byType(ContentRow));
    expect(
      tester.getRect(first).bottom,
      lessThanOrEqualTo(0.62 * screen.height - 8),
    );
  });

  testWidgets('a game row: wide glass cards with both sides, nothing under '
      'them, the competition and matchup in the highlight; an empty row is '
      'not shown', (tester) async {
    final games = parseScoreboard(
      fixture('espn_scoreboard_copa.json'),
      'soccer/bra.copa_do_brazil',
    ).reversed.toList();
    await _open(tester, games: games);
    expect(find.text(t('recommended')), findsNothing);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    final row = find.ancestor(
      of: find.text(t('games')),
      matching: find.byType(ContentRow),
    );
    expect(tester.widget<ContentRow>(row).wide, isTrue);
    for (final abbr in ['GRE', 'CAM', 'PAL', 'VAS']) {
      expect(find.text(abbr), findsOneWidget);
    }
    // In the highlight only: the cards carry no caption.
    expect(find.text('Copa do Brasil'), findsOneWidget);
    expect(find.text('Grêmio × Atlético-MG'), findsOneWidget);
  });

  testWidgets('no inputs, no Inputs row; with them it comes first, wide '
      'glass cards by port, the device in the highlight only, no Watch; one that will '
      'not open says so', (tester) async {
    await _open(tester);
    expect(find.text(t('inputs')), findsNothing);

    // A new home, which asks again.
    await tester.pumpWidget(const SizedBox());
    final inputs = [
      for (final (id, device) in [('hw2', null), ('hw1', 'PlayStation 5')])
        {
          'id': id,
          'type': kTypeHdmi,
          'state': kStateConnected,
          'label': 'HDMI ${id.substring(2)}',
          'systemLabel': 'HDMI ${id.substring(2)}',
          'device': device,
        },
    ];
    await _open(tester, inputs: inputs);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    final row = find.ancestor(
      of: find.text(t('inputs')),
      matching: find.byType(ContentRow),
    );
    expect(tester.widget<ContentRow>(row).wide, isTrue);
    expect(tester.widget<ContentRow>(row).trailerKey, isNull);
    expect(tester.widget<ContentRow>(row).items.map((i) => i.id), [
      'hw1',
      'hw2',
    ]);
    // The PlayStation port wears its wordmark; only the unknown one keeps the
    // HDMI icon and its label. The highlight wears the focused console's
    // wordmark as its title, the port in a chip.
    expect(find.byIcon(Icons.settings_input_hdmi), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (w) =>
            w is Image &&
            w.image is AssetImage &&
            (w.image as AssetImage).assetName == 'assets/inputs/ps5.png',
      ),
      findsNWidgets(2),
    );
    expect(find.text('HDMI 1'), findsOneWidget);
    expect(find.text('PlayStation 5'), findsNothing);
    // Hidden, not gone: the highlight keeps the buttons' room.
    expect(find.text(t('watch')).hitTestable(), findsNothing);

    await _press(tester, LogicalKeyboardKey.enter);
    expect(find.text(t('inputOpenFailed')), findsOneWidget);

    // Unplugged, with focus in the row: it goes, and focus goes to the apps.
    inputs.clear();
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'app.elimor/host',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('inputsChanged'),
          ),
          null,
        );
    await tester.pumpAndSettle();
    expect(find.text(t('inputs')), findsNothing);
    expect(
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorWidgetOfExactType<AppRow>(),
      isNotNull,
    );
  });

  testWidgets('Home from a row: the rows come down at once and the first app '
      'has focus; from Settings too', (tester) async {
    await _open(tester);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final row = find.text(t('trendingMovies'));
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(tester.getRect(row).top, lessThan(screen.height));
    expect(_hint(tester), 0);

    Future<void> home() async {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'app.elimor/host',
            const StandardMethodCodec().encodeMethodCall(
              const MethodCall('goHome'),
            ),
            null,
          );
      // One frame: no animation to wait out.
      await tester.pump();
    }

    await home();
    expect(tester.getRect(row).top, greaterThanOrEqualTo(screen.height));
    expect(
      Focus.of(
        tester.element(
          find.descendant(
            of: find.byType(Tile).first,
            matching: find.byType(FocusLift),
          ),
        ),
      ).hasPrimaryFocus,
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(_hint(tester), 1);

    // From Settings: the screen closes and the home is at the top.
    await _press(tester, LogicalKeyboardKey.contextMenu);
    expect(find.byType(HomeScreen).hitTestable(), findsNothing);
    await home();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen).hitTestable(), findsOneWidget);
    expect(tester.getRect(row).top, greaterThanOrEqualTo(screen.height));
  });

  testWidgets('the store gives the row its apps and icons before Android '
      'answers, and keeps what Android then says', (tester) async {
    final store = MemStore();
    await store.write('apps', {
      'apps': [const InstalledApp(_videos, 'Videos').toJson()],
    });
    final png = Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00,
      0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00, 0x00, 0x00, 0x00,
      0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    await store.writeBytes('icon-$_videos.png', png);
    tester.view
      ..physicalSize = const Size(1920, 1080)
      ..devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    // Android answers listApps only when told to; the icon it gives is a new
    // one.
    final newPng = Uint8List.fromList([...png, 0]);
    final listed = Completer<List<Object?>>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.elimor/host'),
          (call) async => switch (call.method) {
            'listApps' => await listed.future,
            'appIcon' => newPng,
            _ => null,
          },
        );
    SharedPreferences.setMockInitialValues({
      'tiles': jsonEncode([
        const AppTile(_videos, 'app').toJson(),
        const AppTile('elimor:apps', 'apps').toJson(),
      ]),
    });
    final settings = await Settings.load();
    final memStore = MemStore();
    final sources = Sources(
      weather: WeatherSource(settings, memStore, fetch: fake({}).call),
      tmdb: TmdbSource(
        settings,
        memStore,
        fetch: fake({}).call,
        post: fakePost({}).call,
      ),
      stremio: StremioSource(
        settings,
        memStore,
        client: StremioClient(post: fakePost({}).call),
      ),
      youtube: YoutubeSource(
        settings,
        memStore,
        YoutubeTvClient(
          store: MemStore(),
          post: fakePost({}).call,
          getText: (_, {headers = const {}}) =>
              Future.error(const SocketException('offline')),
        ),
      ),
      sports: SportsSource(settings, memStore, fetch: fake({}).call),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: HomeScreen(
          settings,
          sources,
          pairing: Pairing(settings),
          store: store,
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    // The row is up from the store, the tile with the cached icon.
    expect(find.byType(Tile), findsNWidgets(2));
    Uint8List? icon() => tester.widget<Tile>(find.byType(Tile).first).realIcon;
    expect(icon(), png);

    // Android answers: its icon replaces the cached one, and goes to the store.
    listed.complete([
      {'package': _videos, 'label': 'Videos'},
    ]);
    await tester.pump();
    await tester.pump();
    expect(icon(), newPng);
    expect(store.bytes['icon-$_videos.png'], newPng);
    expect(store.bytes['apps'], isNull); // the list is JSON, not bytes
    expect((await store.read('apps'))!['apps'], [
      {'package': _videos, 'label': 'Videos', 'tv': false, 'system': false},
    ]);
  });

  testWidgets('Up from the last app reaches the gear; Down comes back', (
    tester,
  ) async {
    await _open(tester);
    for (var i = 0; i < 10 && !_lastTileFocused(tester); i++) {
      await _press(tester, LogicalKeyboardKey.arrowRight);
    }
    expect(_lastTileFocused(tester), isTrue);
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(_focused(tester, Icons.settings_outlined), isTrue);
    expect(find.byIcon(Icons.search), findsNothing); // no TMDB key
    // Up and Right stay put.
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, Icons.settings_outlined), isTrue);

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_lastTileFocused(tester), isTrue);
    expect(_hint(tester), 1);
  });

  testWidgets('the banner and the pill lead to each other; one white button', (
    tester,
  ) async {
    await _open(tester);
    // What the backdrop says once its image is up: the banner gets buttons.
    tester
        .widget<Backdrop>(find.byType(Backdrop))
        .onShown(const MediaItem(type: MediaType.movie, id: '3', title: 'Up'));
    await tester.pumpAndSettle();
    expect(_watchFill(tester), Colors.white); // no banner button has focus

    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(
      Focus.of(tester.element(find.text(t('watch')))).hasPrimaryFocus,
      isTrue,
    );
    expect(_watchFill(tester), Colors.white);

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, Icons.movie_outlined), isTrue);
    expect(_watchFill(tester), isNot(Colors.white));

    await _press(tester, LogicalKeyboardKey.arrowRight);
    expect(_focused(tester, Icons.settings_outlined), isTrue);
    expect(_watchFill(tester), Colors.white);

    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(_focused(tester, Icons.movie_outlined), isTrue);
  });

  testWidgets('a title that nothing opens says so', (tester) async {
    await _open(tester);
    tester
        .widget<Backdrop>(find.byType(Backdrop))
        .onShown(const MediaItem(type: MediaType.movie, id: '3', title: 'Up'));
    await tester.pumpAndSettle();
    await _press(tester, LogicalKeyboardKey.arrowUp);
    await _press(tester, LogicalKeyboardKey.enter);
    expect(find.text(t('openFailed')), findsOneWidget);
  });

  testWidgets('a trending row with a saved service shows that service\'s '
      'titles and name; a saved service not offered falls back to All; while '
      'the service\'s row loads the default titles stay', (tester) async {
    final gate = Completer<void>();
    final jw = fakePost(_netflixRow);
    await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: (uri, body, {headers = const {}}) async {
        await gate.future;
        return jw.call(uri, body, headers: headers);
      },
      providers: _netflix,
      rowProviders: {'trendingMovies': 8, 'trendingSeries': 999},
    );
    expect(find.text('${t('trendingMovies')} · Netflix'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget, reason: 'the row loads');
    expect(find.text(t('trendingSeries')), findsOneWidget);
    expect(find.text('Show'), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('Film'), findsNothing);
    expect(find.text('Black Doves'), findsOneWidget);
    expect(find.text('Show'), findsOneWidget, reason: 'All: the row as it was');
  });

  testWidgets('picking a service on a trending row saves it and asks for its '
      'row; All brings the row back', (tester) async {
    final jw = fakePost(_netflixRow);
    final settings = await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: jw.call,
      providers: _netflix,
    );
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    final card = find.byKey(const ValueKey('filter'));
    expect(card, findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(settings.rowProvider('trendingMovies'), 8);
    expect(
      (await SharedPreferences.getInstance()).getString('rowProviders'),
      '{"trendingMovies":8}',
    );
    expect(jw.calls, hasLength(1));
    expect(find.text('${t('trendingMovies')} · Netflix'), findsOneWidget);
    expect(find.text('Black Doves'), findsOneWidget);
    expect(card, findsOneWidget, reason: 'the titles swap under the card');
    await _press(tester, LogicalKeyboardKey.arrowUp);
    expect(settings.rowProvider('trendingMovies'), isNull);
    expect(find.text(t('trendingMovies')), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);
  });

  testWidgets('a pick with nothing on it keeps the pick, shows the row as it '
      'is, and Down still reaches the row below', (tester) async {
    await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: (uri, body, {headers = const {}}) async => {
        'data': {
          'popularTitles': {'edges': []},
        },
      },
      providers: _netflix,
      genres: _comedy,
      rowProviders: {'trendingMovies': 8},
      rowGenres: {'trendingMovies': 'hrr'},
    );
    // Nothing for the picks in the country: they stay on the cards and in
    // the name, and the row keeps its own titles under them.
    expect(
      find.text('${t('trendingMovies')} · Netflix · Horror'),
      findsOneWidget,
    );
    expect(find.text('Film'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_rowWithFocus(), '${t('trendingMovies')} · Netflix · Horror');
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_rowWithFocus(), t('trendingSeries'));
  });

  testWidgets('the first fold rotates the country\'s popular titles when it '
      'has them, else the trending films', (tester) async {
    List<String> rotation() => tester
        .widget<Backdrop>(find.byType(Backdrop))
        .rotation
        .map((i) => i.title)
        .toList();
    await _open(tester);
    expect(rotation(), isEmpty, reason: 'Film has no backdrop');
    await _open(
      tester,
      popular: const [
        MediaItem(
          type: MediaType.series,
          id: '1',
          title: 'Hot',
          backdropUrl: 'https://images.justwatch.com/backdrop/1/s1440/hot.jpg',
        ),
        MediaItem(type: MediaType.movie, id: '2', title: 'No backdrop'),
      ],
    );
    expect(rotation(), ['Hot']);
  });

  testWidgets('a genre with no service filters the country\'s popular titles, '
      'and names the row', (tester) async {
    final jw = fakePost(_netflixRow);
    await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: jw.call,
      genres: _comedy,
      rowGenres: {'trendingMovies': 'cmy'},
    );
    expect(find.text('${t('trendingMovies')} · Comedy'), findsOneWidget);
    expect(jw.calls.single.$2['variables']['filter'], {
      'genres': ['cmy'],
      'objectTypes': ['MOVIE'],
    });
    expect(find.text('Black Doves'), findsOneWidget);
  });

  testWidgets('service and genre together name the row with both; picking a '
      'genre on the card saves it and asks for the row', (tester) async {
    final jw = fakePost(_netflixRow);
    final settings = await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: jw.call,
      providers: _netflix,
      genres: _comedy,
      rowProviders: {'trendingMovies': 8},
    );
    expect(find.text('${t('trendingMovies')} · Netflix'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    expect(find.byKey(const ValueKey('genre')), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(settings.rowGenre('trendingMovies'), 'cmy');
    expect(
      (await SharedPreferences.getInstance()).getString('rowGenres'),
      '{"trendingMovies":"cmy"}',
    );
    expect(jw.calls.last.$2['variables']['filter'], {
      'packages': ['nfx'],
      'genres': ['cmy'],
      'objectTypes': ['MOVIE'],
    });
    expect(
      find.text('${t('trendingMovies')} · Netflix · Comedy'),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('genre')), findsOneWidget);
  });

  testWidgets('a saved genre not listed falls back to All', (tester) async {
    final jw = fakePost(_netflixRow);
    await _open(
      tester,
      tmdbKey: 'KEY',
      tmdb: fake(_serviceRoutes).call,
      justWatch: jw.call,
      genres: _comedy,
      rowGenres: {'trendingMovies': 'zzz'},
    );
    expect(find.text(t('trendingMovies')), findsOneWidget);
    expect(jw.calls, isEmpty);
    expect(find.text('Film'), findsOneWidget);
  });

  testWidgets('Home clears the rows\' filters', (tester) async {
    final settings = await _open(
      tester,
      providers: _netflix,
      genres: _comedy,
      rowProviders: {'trendingMovies': 8},
      rowGenres: {'trendingSeries': 'cmy'},
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'app.elimor/host',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('goHome'),
          ),
          null,
        );
    await tester.pumpAndSettle();
    expect(settings.rowProviders, isEmpty);
    expect(settings.rowGenres, isEmpty);
    expect(find.text(t('trendingMovies')), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getString('rowGenres'),
      '{}',
    );
  });

  testWidgets('the genre card: an icon over the name, on one line', (
    tester,
  ) async {
    await _open(
      tester,
      genres: const [Genre('war', 'War & Military')],
      rowGenres: {'trendingMovies': 'war'},
    );
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    await _press(tester, LogicalKeyboardKey.arrowLeft);
    final card = find.byKey(const ValueKey('genre'));
    expect(
      find.descendant(of: card, matching: find.byIcon(Icons.military_tech)),
      findsOneWidget,
    );
    final name = tester.widget<Text>(
      find.descendant(of: card, matching: find.text('War & Military')),
    );
    expect(name.maxLines, 1);
    expect(name.softWrap, isFalse);
  });
}
