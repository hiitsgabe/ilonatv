import 'dart:convert';
import 'dart:io';

import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/youtube_tv.dart';
import 'package:ilonatv/locale.dart';
import 'package:ilonatv/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Transitive, via shared_preferences: the raw store, prefix included.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  // load() reads one shared store; reset it so tests don't see each other.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deviceLocale = () => 'en_CA';
  });
  tearDown(() => deviceLocale = () => Platform.localeName);

  // A dock saved by an earlier run, for the tests that move tiles about.
  void savedTiles() => SharedPreferences.setMockInitialValues({
    'tiles': jsonEncode([
      {'package': 'com.example.videos', 'icon': 'youtube'},
      {'package': 'com.example.tv', 'icon': 'tv'},
      {'package': 'com.stremio.one', 'icon': 'app'},
      {'package': 'ilonatv:apps', 'icon': 'apps'},
    ]),
  });

  List<String> packages(Settings s) => [for (final t in s.tiles) t.package];

  Map<String, Object> content(Settings s) => {
    'tmdbKey': s.tmdbKey,
    'stremioAuthKey': s.stremioAuthKey,
    'stremioEmail': s.stremioEmail,
    'weatherCity': s.weatherCity,
    'weatherLat': s.weatherLat,
    'weatherLon': s.weatherLon,
    'movieProvider': s.movieProvider,
    'seriesProvider': s.seriesProvider,
    'youtubeProvider': s.youtubeProvider,
    'tmdbLanguage': s.tmdbLanguage,
  };

  test('defaults when nothing stored', () async {
    final s = await Settings.load();
    expect(s.tiles.map((t) => t.toJson()), [
      {'package': 'ilonatv:apps', 'icon': 'apps'},
    ]);
    expect(s.fireTvMode, isFalse);
    expect(s.setupDone, isFalse);
    expect(s.language, 'en');
    expect(s.country, 'CA');
    expect(s.fahrenheit, isFalse);
    expect(s.serviceApps, isEmpty);
    // What Kotlin reads is stored by load itself, before any save.
    final stored = await SharedPreferencesStorePlatform.instance.getAll();
    expect(
      [
        stored['flutter.setupDone'],
        stored['flutter.language'],
        stored['flutter.country'],
        stored['flutter.fahrenheit'],
      ],
      [false, 'en', 'CA', false],
    );
  });

  test('the device locale gives the language, country and unit', () async {
    Future<(String, String, bool)> on(String locale) async {
      SharedPreferences.setMockInitialValues({});
      deviceLocale = () => locale;
      final s = await Settings.load();
      return (s.language, s.country, s.fahrenheit);
    }

    expect(await on('pt_BR'), ('pt', 'BR', false));
    expect(await on('pt-PT'), ('pt', 'PT', false));
    expect(await on('en_US'), ('en', 'US', true));
    expect(await on('fr_FR.UTF-8'), ('en', 'FR', false));
    expect(await on('zh_Hans_CN'), ('en', 'CN', false));
    expect(await on('sr-Latn-RS'), ('en', 'RS', false));
    // Stored values win over the device.
    SharedPreferences.setMockInitialValues({
      'language': 'en',
      'country': 'DE',
      'fahrenheit': true,
    });
    deviceLocale = () => 'pt_BR';
    final s = await Settings.load();
    expect((s.language, s.country, s.fahrenheit), ('en', 'DE', true));
  });

  test('setupDone: an install that has prefs is set up', () async {
    expect((await Settings.load()).setupDone, isFalse);
    // Stored at once: the next start is still not set up.
    expect((await Settings.load()).setupDone, isFalse);
    // An older version wrote these on load alone: still not set up.
    SharedPreferences.setMockInitialValues({
      'youtubeDeviceId': 'id',
      'settingsTileDropped': true,
    });
    expect((await Settings.load()).setupDone, isFalse);
    // Only save() wrote the tiles: set up, and Celsius as before.
    deviceLocale = () => 'en_US';
    SharedPreferences.setMockInitialValues({'tiles': '[]'});
    final up = await Settings.load();
    expect((up.setupDone, up.fahrenheit), (true, false));
    final s = await Settings.load();
    s.setupDone = false;
    await s.save();
    expect((await Settings.load()).setupDone, isFalse);
  });

  test('a tile saved with a retired logo icon shows the app\'s own', () async {
    SharedPreferences.setMockInitialValues({
      'tiles': jsonEncode([
        {'package': 'com.example.tv', 'icon': 'globoplay'},
        {'package': 'com.stremio.one', 'icon': 'netflix'},
        {'package': 'com.example.player', 'icon': 'tv'},
      ]),
    });
    final s = await Settings.load();
    expect(s.tiles.map((t) => t.icon), ['app', 'app', 'tv']);
  });

  test('serviceApps round trip; unreadable reads as none', () async {
    final s = await Settings.load();
    s.serviceApps = {'8': 'com.example.netflix', '337': 'com.example.disney'};
    await s.save();
    expect((await Settings.load()).serviceApps, s.serviceApps);
    for (final bad in ['nope', '[]', '{"8": 1}']) {
      SharedPreferences.setMockInitialValues({'serviceApps': bad});
      expect((await Settings.load()).serviceApps, isEmpty, reason: bad);
    }
  });

  test('a saved row loses its Settings tile once', () async {
    SharedPreferences.setMockInitialValues({
      'tiles': jsonEncode([
        {'package': 'com.example.videos', 'icon': 'youtube'},
        {'package': 'ilonatv:settings', 'icon': 'settings'},
      ]),
    });
    expect((await Settings.load()).tiles.map((t) => t.package), [
      'com.example.videos',
    ]);
    // Persisted: the next start keeps the row as it was left.
    expect((await Settings.load()).tiles.map((t) => t.package), [
      'com.example.videos',
    ]);
    SharedPreferences.setMockInitialValues({
      'settingsTileDropped': true,
      'tiles': jsonEncode([
        {'package': 'ilonatv:settings', 'icon': 'settings'},
      ]),
    });
    expect((await Settings.load()).tiles.map((t) => t.package), [
      'ilonatv:settings',
    ]);
  });

  test('round trip', () async {
    savedTiles();
    final s = await Settings.load();
    s.setTileIcon(0, 'app');
    s.removeTileAt(1);
    s.addTile(const AppTile('com.example.player', 'plex'));
    s.fireTvMode = true;
    s.language = 'pt';
    s.setupDone = true;
    s.country = 'PT';
    s.fahrenheit = true;
    await s.save();

    final r = await Settings.load();
    expect(r.tiles.map((t) => t.toJson()), [
      {'package': 'com.example.videos', 'icon': 'app'},
      {'package': 'com.stremio.one', 'icon': 'app'},
      {'package': 'ilonatv:apps', 'icon': 'apps'},
      {'package': 'com.example.player', 'icon': 'plex'},
    ]);
    expect(r.fireTvMode, isTrue);
    expect(r.language, 'pt');
    expect((r.setupDone, r.country, r.fahrenheit), (true, 'PT', true));
  });

  test('a tile with a custom image round trips; one without keeps its old '
      'shape; unknown fields are ignored', () async {
    const fill = AppTile('com.example.tv', 'tv', image: '/files/tiles/1.img');
    const centered = AppTile(
      'com.example.videos',
      'youtube',
      image: '/files/tiles/2.img',
      centered: true,
      background: 0xFF1F2A44,
    );
    const glass = AppTile(
      'com.example.player',
      'app',
      image: '/files/tiles/3.img',
      centered: true,
    );
    SharedPreferences.setMockInitialValues({
      'tiles': jsonEncode([
        {'package': 'ilonatv:apps', 'icon': 'apps', 'later': 1},
        fill,
        centered,
        glass,
      ]),
    });
    final s = await Settings.load();
    expect(s.tiles.first.toJson(), {'package': 'ilonatv:apps', 'icon': 'apps'});
    expect(s.tiles[1].toJson(), {
      'package': 'com.example.tv',
      'icon': 'tv',
      'image': '/files/tiles/1.img',
    });
    await s.save();
    final r = await Settings.load();
    expect(
      [for (final t in r.tiles) (t.image, t.centered, t.background)],
      [
        (null, false, null),
        ('/files/tiles/1.img', false, null),
        ('/files/tiles/2.img', true, 0xFF1F2A44),
        ('/files/tiles/3.img', true, null),
      ],
    );
    expect(r.tiles.map((t) => t.icon), ['apps', 'tv', 'youtube', 'app']);
  });

  test('rowProviders round trip; null removes', () async {
    final s = await Settings.load();
    expect(s.rowProvider('trendingMovies'), isNull);
    s.setRowProvider('trendingMovies', 8);
    s.setRowProvider('trendingSeries', 350);
    s.setRowProvider('trendingSeries', null);
    expect(s.rowProvider('trendingMovies'), 8);
    await s.save();
    final again = await Settings.load();
    expect(again.rowProviders, {'trendingMovies': 8});
  });

  test('rowGenres round trip; null removes', () async {
    final s = await Settings.load();
    expect(s.rowGenre('trendingSeries'), isNull);
    s.setRowGenre('trendingSeries', 'cmy');
    s.setRowGenre('trendingMovies', 'hrr');
    s.setRowGenre('trendingMovies', null);
    expect(s.rowGenre('trendingSeries'), 'cmy');
    await s.save();
    final again = await Settings.load();
    expect(again.rowGenres, {'trendingSeries': 'cmy'});
  });

  test('content fields default and round trip', () async {
    final s = await Settings.load();
    expect(content(s), {
      'tmdbKey': '',
      'stremioAuthKey': '',
      'stremioEmail': '',
      'weatherCity': '',
      'weatherLat': 0.0,
      'weatherLon': 0.0,
      'movieProvider': '',
      'seriesProvider': '',
      'youtubeProvider': '',
      'tmdbLanguage': 'en-US',
    });

    s
      ..tmdbKey = 'KEY'
      ..stremioAuthKey = 'AK'
      ..stremioEmail = 'a@b'
      ..weatherCity = 'Lisboa'
      ..weatherLat = 38.7
      ..weatherLon = -9.1
      ..movieProvider = 'com.example.movies'
      ..seriesProvider = 'com.example.series'
      ..youtubeProvider = 'com.google.android.youtube.tv'
      ..language = 'pt';
    await s.save();

    final r = await Settings.load();
    expect(content(r), {
      'tmdbKey': 'KEY',
      'stremioAuthKey': 'AK',
      'stremioEmail': 'a@b',
      'weatherCity': 'Lisboa',
      'weatherLat': 38.7,
      'weatherLon': -9.1,
      'movieProvider': 'com.example.movies',
      'seriesProvider': 'com.example.series',
      'youtubeProvider': 'com.google.android.youtube.tv',
      'tmdbLanguage': 'pt-BR',
    });
  });

  test(
    'companionSecret is made once and kept, and setup is still due',
    () async {
      final s = await Settings.load();
      expect(s.companionSecret, matches(RegExp(r'^[0-9a-f]{32}$')));
      expect(s.setupDone, isFalse);
      final again = await Settings.load();
      expect(again.companionSecret, s.companionSecret);
      expect(again.setupDone, isFalse);
      SharedPreferences.setMockInitialValues({});
      expect((await Settings.load()).companionSecret, isNot(s.companionSecret));
    },
  );

  test(
    'companionSecret is kept under the key PairingProvider reads over adb',
    () async {
      final s = await Settings.load();
      var stored = await SharedPreferencesStorePlatform.instance.getAll();
      expect(stored['flutter.companionSecret'], s.companionSecret);
      s.companionSecret = 'renewed';
      await s.save();
      stored = await SharedPreferencesStorePlatform.instance.getAll();
      expect(stored['flutter.companionSecret'], 'renewed');
    },
  );

  test('companionDevices round trip', () async {
    final s = await Settings.load();
    expect(s.companionDevices, isEmpty);
    s.companionDevices = {'t1': 'Mac', 't2': 'Phone'};
    await s.save();
    expect((await Settings.load()).companionDevices, {
      't1': 'Mac',
      't2': 'Phone',
    });
  });

  test('youtubeDeviceId is a v4 UUID, made once and kept', () async {
    final s = await Settings.load();
    expect(
      s.youtubeDeviceId,
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    // Kept by load itself, before any save.
    expect((await Settings.load()).youtubeDeviceId, s.youtubeDeviceId);
    SharedPreferences.setMockInitialValues({});
    expect((await Settings.load()).youtubeDeviceId, isNot(s.youtubeDeviceId));
  });

  test(
    'recent searches: newest first, once whatever the case, six, kept',
    () async {
      final s = await Settings.load();
      expect(s.recentSearches, isEmpty);
      for (final q in ['a', 'b', 'c', 'd', 'e', 'f', 'g']) {
        s.addRecentSearch(q);
      }
      s.addRecentSearch('D');
      expect(s.recentSearches, ['D', 'g', 'f', 'e', 'c', 'b']);
      await s.save();
      expect((await Settings.load()).recentSearches, s.recentSearches);
    },
  );

  test('youtubeAccounts round trip; unreadable ones read as none', () async {
    final s = await Settings.load();
    expect(s.youtubeAccounts, isEmpty);
    s.youtubeAccounts = [
      const YtAccount(
        refreshToken: 'REFRESH',
        name: 'Alex',
        avatarUrl: 'https://a',
      ),
      const YtAccount(
        refreshToken: 'REFRESH',
        name: 'Kids',
        pageId: 'P',
        enabled: false,
      ),
    ];
    await s.save();
    final r = await Settings.load();
    expect(
      [for (final a in r.youtubeAccounts) a.toJson()],
      [for (final a in s.youtubeAccounts) a.toJson()],
    );

    SharedPreferences.setMockInitialValues({
      'youtubeAccounts': jsonEncode([
        {'refreshToken': 'R', 'name': 'Old'},
      ]),
    });
    expect((await Settings.load()).youtubeAccounts.single.enabled, isTrue);
    for (final bad in ['not json', '[1]', '{}']) {
      SharedPreferences.setMockInitialValues({'youtubeAccounts': bad});
      expect((await Settings.load()).youtubeAccounts, isEmpty, reason: bad);
    }
  });

  test('what Kotlin reads is stored under its keys', () async {
    final s = await Settings.load();
    s
      ..fireTvMode = true
      ..weatherCity = 'Lisboa'
      ..weatherLat = 38.7
      ..weatherLon = -9.1
      ..fahrenheit = true;
    await s.save();
    final stored = await SharedPreferencesStorePlatform.instance.getAll();
    expect(
      [
        stored['flutter.fireTvMode'],
        stored['flutter.weatherCity'],
        stored['flutter.weatherLat'],
        stored['flutter.weatherLon'],
        stored['flutter.fahrenheit'],
      ],
      [true, 'Lisboa', 38.7, -9.1, true],
    );
  });

  test('a corrupt tiles pref falls back to the factory tiles', () async {
    final factory = (await Settings.load()).tiles.map((t) => t.toJson());
    for (final bad in [
      '',
      'not json',
      '{"package":"x","icon":"y"}',
      '[1]',
      '[{"package":"x"}]',
    ]) {
      SharedPreferences.setMockInitialValues({
        'tiles': bad,
        'fireTvMode': true,
        'language': 'pt',
      });
      final s = await Settings.load();
      expect(s.tiles.map((t) => t.toJson()), factory, reason: bad);
      // The other two keys are read independently of the tiles.
      expect(s.fireTvMode, isTrue, reason: bad);
      expect(s.language, 'pt', reason: bad);
    }
  });

  test(
    'visibleTiles omits uninstalled but keeps pseudo packages and config',
    () async {
      savedTiles();
      final s = await Settings.load();
      final v = s.visibleTiles({'com.example.videos'});
      expect(v.map((t) => t.package), ['com.example.videos', 'ilonatv:apps']);
      expect(s.tiles.length, 4);
    },
  );

  test('moveTile and removeTileAt', () async {
    savedTiles();
    final s = await Settings.load();
    s.addTile(const AppTile('ilonatv:settings', 'settings'));

    s.moveTile(0, 2);
    expect(packages(s), [
      'com.example.tv',
      'com.stremio.one',
      'com.example.videos',
      'ilonatv:apps',
      'ilonatv:settings',
    ]);

    s.removeTileAt(1);
    expect(packages(s), [
      'com.example.tv',
      'com.example.videos',
      'ilonatv:apps',
      'ilonatv:settings',
    ]);
  });

  test('moveTile reaches the last slot, ignores bad indices', () async {
    savedTiles();
    final s = await Settings.load();
    s.addTile(const AppTile('ilonatv:settings', 'settings'));

    s.moveTile(0, 4);
    final moved = [
      'com.example.tv',
      'com.stremio.one',
      'ilonatv:apps',
      'ilonatv:settings',
      'com.example.videos',
    ];
    expect(packages(s), moved);

    for (final (from, to) in [(-1, 0), (0, -1), (5, 0), (0, 5)]) {
      s.moveTile(from, to);
      expect(packages(s), moved, reason: 'moveTile($from, $to)');
    }
  });

  test('save notifies listeners; the mutators do not', () async {
    final s = await Settings.load();
    var calls = 0;
    s.addListener(() => calls++);

    s.addTile(const AppTile('com.example.player', 'plex'));
    s.setTileIcon(0, 'app');
    s.moveTile(0, 1);
    s.removeTileAt(0);
    expect(calls, 0);

    await s.save();
    expect(calls, 1);
  });

  test('homeRows: the home order, all on, by default; round trip', () async {
    final s = await Settings.load();
    expect([for (final r in s.homeRows) r.key], kHomeRows);
    expect(s.homeRows.every((r) => r.on), isTrue);
    s.homeRows = [
      (key: 'youtube', on: false),
      ...s.homeRows.where((r) => r.key != 'youtube'),
    ];
    await s.save();
    expect((await Settings.load()).homeRows, s.homeRows);
  });

  test('homeRows load: missing keys come last and on, the inputs first; '
      'unknown, repeated and unreadable ones go', () async {
    SharedPreferences.setMockInitialValues({
      'homeRows': jsonEncode([
        {'key': 'recommended', 'on': false},
        {'key': 'gone', 'on': true},
        {'key': 'youtube', 'on': true},
        {'key': 'recommended', 'on': true},
      ]),
    });
    expect((await Settings.load()).homeRows, [
      (key: 'inputs', on: true),
      (key: 'recommended', on: false),
      (key: 'youtube', on: true),
      (key: 'continueWatching', on: true),
      (key: 'youtubeContinue', on: true),
      (key: 'games', on: true),
      (key: 'trendingMovies', on: true),
      (key: 'trendingSeries', on: true),
    ]);
    // Once saved, the inputs keep their place and their switch.
    SharedPreferences.setMockInitialValues({
      'homeRows': jsonEncode([
        {'key': 'youtube', 'on': true},
        {'key': 'inputs', 'on': false},
      ]),
    });
    expect(
      [for (final r in (await Settings.load()).homeRows.take(3)) r],
      [
        (key: 'youtube', on: true),
        (key: 'inputs', on: false),
        (key: 'continueWatching', on: true),
      ],
    );
    for (final bad in ['nope', '{}', '[{"key": 1}]']) {
      SharedPreferences.setMockInitialValues({'homeRows': bad});
      expect(
        [for (final r in (await Settings.load()).homeRows) r.key],
        kHomeRows,
        reason: bad,
      );
    }
  });

  test('homeRows load: the two games rows of before are the games row, at '
      'the first one\'s place with its switch', () async {
    SharedPreferences.setMockInitialValues({
      'homeRows': jsonEncode([
        {'key': 'inputs', 'on': true},
        {'key': 'gamesToronto', 'on': false},
        {'key': 'youtube', 'on': true},
        {'key': 'matchesBrazil', 'on': true},
      ]),
    });
    final rows = (await Settings.load()).homeRows;
    expect(rows.take(3), [
      (key: 'inputs', on: true),
      (key: 'games', on: false),
      (key: 'youtube', on: true),
    ]);
    expect(rows.where((r) => r.key == 'games'), hasLength(1));
  });

  test('sports: none by default; leagues and teams round trip in order; '
      'unreadable reads as none', () async {
    final s = await Settings.load();
    expect(s.sports, isEmpty);
    s.sports = [
      const SportsFollow(
        'basketball/nba',
        'NBA',
        onlyTeams: true,
        teams: [SportsTeam('2', 'Boston Celtics'), SportsTeam('13', 'Lakers')],
      ),
      const SportsFollow('soccer/eng.1', 'English Premier League'),
    ];
    await s.save();
    final back = (await Settings.load()).sports;
    expect(jsonEncode(back), jsonEncode(s.sports));
    expect(
      [for (final f in back) f.league],
      ['basketball/nba', 'soccer/eng.1'],
    );
    expect(back.first.onlyTeams, isTrue);
    expect([for (final t in back.first.teams) t.id], ['2', '13']);
    expect(back.last.teams, isEmpty);
    SharedPreferences.setMockInitialValues({'sports': '[{"league": 1}]'});
    expect((await Settings.load()).sports, isEmpty);
  });

  test('shownRows follows homeRows, skipping rows off or empty', () async {
    final s = await Settings.load();
    MediaItem item(String id) =>
        MediaItem(type: MediaType.video, id: id, title: id);
    s.homeRows = [
      (key: 'youtube', on: true),
      (key: 'recommended', on: false),
      (key: 'trendingMovies', on: true),
      (key: 'continueWatching', on: true),
    ];
    final rows = s.shownRows({
      'continueWatching': [],
      'trendingMovies': [item('m')],
      'recommended': [item('r')],
      'youtube': [item('v')],
    });
    expect([for (final (key, _) in rows) key], ['youtube', 'trendingMovies']);
    expect(rows.first.$2.single.id, 'v');
  });

  test('hiddenApps: the four Fire OS apps until saved; round trip', () async {
    final s = await Settings.load();
    expect(s.hiddenApps, kDefaultHiddenApps);
    expect(s.hiddenApps, contains('com.amazon.spiderpork'));
    s.hiddenApps
      ..remove('com.amazon.firebat')
      ..add('com.example.x');
    await s.save();
    final again = await Settings.load();
    expect(again.hiddenApps, {
      'com.amazon.firetv.troubleshooting',
      'com.amazon.shoptv.firetv.client',
      'com.amazon.spiderpork',
      'com.example.x',
    });
    // All switched back on stays so: the defaults do not return.
    again.hiddenApps.clear();
    await again.save();
    expect((await Settings.load()).hiddenApps, isEmpty);
  });
}
