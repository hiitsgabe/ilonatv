import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/media.dart';
import 'data/weather.dart' show Place;
import 'data/youtube_tv.dart';
import 'locale.dart';

/// The Stremio build whose screens the accessibility service knows (the view
/// ids HomeWatcher.kt taps to play a title's first stream).
const kStremioPackage = 'com.stremio.one';

/// The countries that give temperatures in Fahrenheit.
const _fahrenheitCountries = {'US', 'BS', 'BZ', 'KY', 'LR', 'PW', 'FM', 'MH'};

/// One slot of the app row. [package] is an installed package or a pseudo
/// package (`ilonatv:apps`, `ilonatv:settings`); [icon] names a drawn icon, or is
/// `app` for the app's own icon.
class AppTile {
  final String package;
  final String icon;

  /// A picture of the user's, copied into Ilona TV's files: drawn in [icon]'s
  /// place, covering the card, or with [centered] contained in its middle
  /// over [background] (ARGB; null is glass).
  final String? image;
  final bool centered;
  final int? background;

  const AppTile(
    this.package,
    this.icon, {
    this.image,
    this.centered = false,
    this.background,
  });

  Map<String, Object> toJson() => {
    'package': package,
    'icon': icon,
    'image': ?image,
    if (centered) 'centered': true,
    'background': ?background,
  };

  factory AppTile.fromJson(Map json) => AppTile(
    json['package'] as String,
    json['icon'] as String,
    image: json['image'] as String?,
    centered: json['centered'] == true,
    background: json['background'] as int?,
  );
}

/// Logo icons that no longer ship: a tile saved with one shows the app's own.
AppTile _retired(AppTile t) => t.icon == 'netflix' || t.icon == 'globoplay'
    ? AppTile(t.package, 'app')
    : t;

/// The pseudo tiles of the build before Ilona TV, `elimor:apps` and
/// `elimor:settings`, which an imported row still has.
AppTile _renamed(AppTile t) => t.package.startsWith('elimor:')
    ? AppTile(
        'ilonatv:${t.package.substring('elimor:'.length)}',
        t.icon,
        image: t.image,
        centered: t.centered,
        background: t.background,
      )
    : t;

/// A team followed in a league: its games come first in the home's games row.
class SportsTeam {
  /// ESPN's id of the team.
  final String id;
  final String name;
  const SportsTeam(this.id, this.name);

  Map<String, String> toJson() => {'id': id, 'name': name};

  factory SportsTeam.fromJson(Map json) =>
      SportsTeam(json['id'] as String, json['name'] as String);
}

/// A league whose games the home shows: every game, or with [onlyTeams] only
/// the games of [teams].
class SportsFollow {
  /// ESPN's path of the league, `soccer/eng.1`, `basketball/nba`.
  final String league;
  final String name;
  final bool onlyTeams;
  final List<SportsTeam> teams;
  const SportsFollow(
    this.league,
    this.name, {
    this.onlyTeams = false,
    this.teams = const [],
  });

  Map<String, dynamic> toJson() => {
    'league': league,
    'name': name,
    'onlyTeams': onlyTeams,
    'teams': teams,
  };

  factory SportsFollow.fromJson(Map json) => SportsFollow(
    json['league'] as String,
    json['name'] as String,
    onlyTeams: json['onlyTeams'] as bool? ?? false,
    teams: [
      for (final t in json['teams'] as List? ?? const [])
        SportsTeam.fromJson(t as Map),
    ],
  );
}

/// Each followed league costs three requests a refresh.
const kMaxSportsLeagues = 8;

/// The Apps grid alone: the first-run setup adds the chosen apps. Settings has
/// its own gear in the home's corner pill, so its tile is optional.
const _factoryTiles = [AppTile('ilonatv:apps', 'apps')];

/// How many searches the search screen offers again.
const kRecentSearches = 6;

/// The home's content rows, each named by its i18n key, in their default
/// order.
const kHomeRows = [
  'inputs',
  'continueWatching',
  'youtubeContinue',
  'games',
  'trendingMovies',
  'trendingSeries',
  'recommended',
  'youtube',
];

typedef HomeRow = ({String key, bool on});

/// Rows of earlier versions that are the games row now.
const _gamesRows = {'matchesBrazil', 'gamesToronto'};

/// Fire OS apps the Apps grid leaves out until switched on in Settings.
const kDefaultHiddenApps = {
  'com.amazon.firetv.troubleshooting',
  'com.amazon.shoptv.firetv.client',
  'com.amazon.firebat',
  'com.amazon.spiderpork',
};

/// Stored in `shared_preferences`, each field under a key named like it (lists
/// and maps as JSON). Kotlin reads `fireTvMode`, `doublePowerFix`,
/// `alexaBounce`, `assistantColor`, `language`, `geminiKey`, `tmdbKey`,
/// `weatherCity`, `weatherLat`, `weatherLon` and `fahrenheit` as
/// `flutter.<key>`, so keep those keys and their types.
/// The mutators only change memory; call [save] to persist and notify
/// listeners.
class Settings extends ChangeNotifier {
  List<AppTile> tiles;
  bool fireTvMode;
  String language;

  /// Undoes the second half of one press on a remote that sends power twice
  /// (IR and Bluetooth): read by the accessibility service as
  /// `flutter.doublePowerFix`.
  bool doublePowerFix = false;

  /// Stremio plays a title's first stream at once (HomeWatcher.kt taps it)
  /// instead of stopping on the list of streams.
  bool stremioAutoPlay = true;

  /// The remote's mic button opens Ilona TV instead of Alexa: the accessibility
  /// service dismisses Alexa's window and comes to the front
  /// (`flutter.alexaBounce`, HomeWatcher.onAlexa). Fire OS still hears the
  /// button, so Alexa may flash before Ilona TV takes over.
  bool alexaBounce = false;

  /// The one colour the assistant screen's gradient is built from (ARGB).
  int assistantColor = 0xFF4F8CFF;

  // Content rows. The value written here is what load() uses when nothing is
  // stored.
  String tmdbKey = '';
  String stremioAuthKey = '';
  String stremioEmail = '';

  /// The voice assistant's Gemini key; the native side reads it as
  /// flutter.geminiKey. Empty = the assistant answers with a "no key" notice.
  String geminiKey = '';

  /// Empty: no weather is asked for or shown.
  String weatherCity = '';
  double weatherLat = 0;
  double weatherLon = 0;

  /// Empty for movies and series: each title opens in a streaming app that
  /// has it ([serviceApps]); empty for videos: any app that opens YouTube.
  String movieProvider = '';
  String seriesProvider = '';
  String youtubeProvider = '';

  /// This install's id for YouTube's sign-in, made on the first [load].
  String youtubeDeviceId = '';
  List<YtAccount> youtubeAccounts = [];

  /// 32 hex characters that pair a phone by QR; made on the first [load].
  String companionSecret = '';

  /// Paired phones: token -> the name the phone gave.
  Map<String, String> companionDevices = {};

  /// Packages the Apps grid and the app picker leave out; stored as a JSON
  /// list, the defaults until the first save.
  Set<String> hiddenApps = {...kDefaultHiddenApps};

  /// The last searches, newest first, at most [kRecentSearches].
  List<String> recentSearches = [];

  /// The content rows in the home's order, each on or off.
  List<HomeRow> homeRows = [for (final k in kHomeRows) (key: k, on: true)];

  /// False until the first-run setup is done or skipped.
  bool setupDone = false;

  /// ISO 3166-1 alpha-2, upper case: where streaming services are looked up.
  String country = 'US';

  bool fahrenheit = false;

  /// The games row as one row per sport.
  bool gamesBySport = false;

  /// TMDB watch-provider id (as a string) -> the package that opens it.
  Map<String, String> serviceApps = {};

  /// The leagues of the games row, in the order their teams come first.
  List<SportsFollow> sports = [];

  /// The streaming service a trending row is filtered by, by row key (TMDB's
  /// provider id); a row absent here shows everything.
  Map<String, int> rowProviders = {};

  int? rowProvider(String key) => rowProviders[key];

  /// [id] null takes the filter off.
  void setRowProvider(String key, int? id) {
    if (id == null) {
      rowProviders.remove(key);
    } else {
      rowProviders[key] = id;
    }
  }

  /// The genre a trending row is filtered by, by row key (JustWatch's code,
  /// `cmy`); a row absent here shows every genre.
  Map<String, String> rowGenres = {};

  String? rowGenre(String key) => rowGenres[key];

  /// [code] null takes the filter off.
  void setRowGenre(String key, String? code) {
    if (code == null) {
      rowGenres.remove(key);
    } else {
      rowGenres[key] = code;
    }
  }

  Settings._(this.tiles, this.fireTvMode, this.language);

  /// The language TMDB is asked for.
  String get tmdbLanguage => language == 'pt' ? 'pt-BR' : 'en-US';

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    // First, before any write. Only save() writes `tiles`, so an install
    // that never saved still gets the wizard.
    final upgraded =
        prefs.getBool('setupDone') == null && prefs.containsKey('tiles');
    final setupDone = prefs.getBool('setupDone') ?? upgraded;
    await prefs.setBool('setupDone', setupDone);
    var tiles = [..._factoryTiles];
    final json = prefs.getString('tiles');
    if (json != null) {
      try {
        tiles = [
          for (final t in jsonDecode(json) as List)
            _retired(_renamed(AppTile.fromJson(t))),
        ];
      } catch (_) {
        // ponytail: one bad entry resets the whole row to the factory tiles;
        // keep the good entries if that ever bites.
      }
      // Once, for rows saved before the corner gear: Settings leaves the row
      // (it can be added back as a tile).
      if (prefs.getBool('settingsTileDropped') != true) {
        tiles.removeWhere((t) => t.package == 'ilonatv:settings');
        await prefs.setString('tiles', jsonEncode(tiles));
      }
    }
    await prefs.setBool('settingsTileDropped', true);
    final s = Settings._(
      tiles,
      prefs.getBool('fireTvMode') ?? false,
      prefs.getString('language') ?? deviceLanguage(),
    );
    s.setupDone = setupDone;
    s.country = prefs.getString('country') ?? deviceCountry();
    // An upgraded install keeps Celsius, the only unit before.
    s.fahrenheit =
        prefs.getBool('fahrenheit') ??
        (!upgraded && _fahrenheitCountries.contains(s.country));
    // Kotlin reads these, so a default is stored at once.
    await prefs.setString('language', s.language);
    await prefs.setString('country', s.country);
    await prefs.setBool('fahrenheit', s.fahrenheit);
    s.doublePowerFix = prefs.getBool('doublePowerFix') ?? false;
    s.stremioAutoPlay = prefs.getBool('stremioAutoPlay') ?? true;
    s.alexaBounce = prefs.getBool('alexaBounce') ?? false;
    s.gamesBySport = prefs.getBool('gamesBySport') ?? false;
    s.assistantColor = prefs.getInt('assistantColor') ?? s.assistantColor;
    s.tmdbKey = prefs.getString('tmdbKey') ?? s.tmdbKey;
    s.geminiKey = prefs.getString('geminiKey') ?? s.geminiKey;
    s.stremioAuthKey = prefs.getString('stremioAuthKey') ?? s.stremioAuthKey;
    s.stremioEmail = prefs.getString('stremioEmail') ?? s.stremioEmail;
    s.weatherCity = prefs.getString('weatherCity') ?? s.weatherCity;
    s.weatherLat = prefs.getDouble('weatherLat') ?? s.weatherLat;
    s.weatherLon = prefs.getDouble('weatherLon') ?? s.weatherLon;
    s.movieProvider = prefs.getString('movieProvider') ?? s.movieProvider;
    s.seriesProvider = prefs.getString('seriesProvider') ?? s.seriesProvider;
    s.youtubeProvider = prefs.getString('youtubeProvider') ?? s.youtubeProvider;
    s.youtubeDeviceId = prefs.getString('youtubeDeviceId') ?? '';
    if (s.youtubeDeviceId.isEmpty) {
      s.youtubeDeviceId = _uuid4();
      await prefs.setString('youtubeDeviceId', s.youtubeDeviceId);
    }
    s.companionSecret = prefs.getString('companionSecret') ?? '';
    if (s.companionSecret.isEmpty) {
      s.companionSecret = randomHex();
      await prefs.setString('companionSecret', s.companionSecret);
    }
    final devices = prefs.getString('companionDevices');
    if (devices != null) {
      try {
        s.companionDevices = Map<String, String>.from(
          jsonDecode(devices) as Map,
        );
      } catch (_) {} // ponytail: unreadable reads as none
    }
    final accounts = prefs.getString('youtubeAccounts');
    if (accounts != null) {
      try {
        s.youtubeAccounts = [
          for (final a in jsonDecode(accounts) as List) YtAccount.fromJson(a),
        ];
      } catch (_) {} // ponytail: unreadable list reads as none, like tiles
    }
    final recent = prefs.getString('recentSearches');
    if (recent != null) {
      try {
        s.recentSearches = (jsonDecode(recent) as List).cast<String>();
      } catch (_) {} // ponytail: unreadable reads as none
    }
    final hidden = prefs.getString('hiddenApps');
    if (hidden != null) {
      try {
        s.hiddenApps = {...(jsonDecode(hidden) as List).cast<String>()};
      } catch (_) {} // ponytail: unreadable reads as the defaults
    }
    final services = prefs.getString('serviceApps');
    if (services != null) {
      try {
        s.serviceApps = Map<String, String>.from(jsonDecode(services) as Map);
      } catch (_) {} // ponytail: unreadable reads as none
    }
    final sports = prefs.getString('sports');
    if (sports != null) {
      try {
        s.sports = [
          for (final f in jsonDecode(sports) as List)
            SportsFollow.fromJson(f as Map),
        ];
      } catch (_) {} // ponytail: unreadable reads as none
    }
    final providers = prefs.getString('rowProviders');
    if (providers != null) {
      try {
        s.rowProviders = {
          for (final MapEntry(:key, :value)
              in (jsonDecode(providers) as Map).entries)
            key as String: (value as num).toInt(),
        };
      } catch (_) {} // ponytail: unreadable reads as no filters
    }
    final genres = prefs.getString('rowGenres');
    if (genres != null) {
      try {
        s.rowGenres = {
          for (final MapEntry(:key, :value)
              in (jsonDecode(genres) as Map).entries)
            key as String: value as String,
        };
      } catch (_) {} // ponytail: unreadable reads as no filters
    }
    final rows = prefs.getString('homeRows');
    if (rows != null) {
      try {
        final saved = [
          for (final r in jsonDecode(rows) as List)
            (
              key: _gamesRows.contains(r['key']) ? 'games' : r['key'] as String,
              on: r['on'] as bool,
            ),
        ];
        // Unknown and repeated keys go; rows added since come last, on, but
        // the inputs, which come first.
        final seen = <String>{};
        final kept = [
          for (final r in saved)
            if (kHomeRows.contains(r.key) && seen.add(r.key)) r,
        ];
        s.homeRows = [
          if (!seen.contains('inputs')) (key: 'inputs', on: true),
          ...kept,
          for (final k in kHomeRows)
            if (!seen.contains(k) && k != 'inputs') (key: k, on: true),
        ];
      } catch (_) {} // ponytail: unreadable reads as the default order
    }
    return s;
  }

  /// The weather's city is [place], and the country is its country when it
  /// has one; saved.
  Future<void> applyPlace(Place place) {
    weatherCity = place.name;
    weatherLat = place.lat;
    weatherLon = place.lon;
    if (place.countryCode.isNotEmpty) country = place.countryCode.toUpperCase();
    return save();
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('setupDone', setupDone);
    await prefs.setString('tiles', jsonEncode(tiles));
    await prefs.setBool('fireTvMode', fireTvMode);
    await prefs.setBool('doublePowerFix', doublePowerFix);
    await prefs.setBool('stremioAutoPlay', stremioAutoPlay);
    await prefs.setBool('alexaBounce', alexaBounce);
    await prefs.setInt('assistantColor', assistantColor);
    await prefs.setString('language', language);
    await prefs.setString('tmdbKey', tmdbKey);
    await prefs.setString('geminiKey', geminiKey);
    await prefs.setString('stremioAuthKey', stremioAuthKey);
    await prefs.setString('stremioEmail', stremioEmail);
    await prefs.setString('weatherCity', weatherCity);
    await prefs.setDouble('weatherLat', weatherLat);
    await prefs.setDouble('weatherLon', weatherLon);
    await prefs.setString('country', country);
    await prefs.setBool('fahrenheit', fahrenheit);
    await prefs.setBool('gamesBySport', gamesBySport);
    await prefs.setString('serviceApps', jsonEncode(serviceApps));
    await prefs.setString('sports', jsonEncode(sports));
    await prefs.setString('movieProvider', movieProvider);
    await prefs.setString('seriesProvider', seriesProvider);
    await prefs.setString('youtubeProvider', youtubeProvider);
    await prefs.setString('youtubeDeviceId', youtubeDeviceId);
    await prefs.setString('companionSecret', companionSecret);
    await prefs.setString('companionDevices', jsonEncode(companionDevices));
    await prefs.setString('youtubeAccounts', jsonEncode(youtubeAccounts));
    await prefs.setString('hiddenApps', jsonEncode([...hiddenApps]));
    await prefs.setString('recentSearches', jsonEncode(recentSearches));
    await prefs.setString('rowProviders', jsonEncode(rowProviders));
    await prefs.setString('rowGenres', jsonEncode(rowGenres));
    await prefs.setString(
      'homeRows',
      jsonEncode([
        for (final r in homeRows) {'key': r.key, 'on': r.on},
      ]),
    );
    notifyListeners();
  }

  /// [query] first among [recentSearches], once whatever its case, the
  /// oldest past [kRecentSearches] dropped.
  void addRecentSearch(String query) => recentSearches = [
    query,
    ...recentSearches.where((q) => q.toLowerCase() != query.toLowerCase()),
  ].take(kRecentSearches).toList();

  /// Stores [recentSearches] alone: no listener has anything to redo.
  Future<void> saveRecentSearches() async =>
      (await SharedPreferences.getInstance()).setString(
        'recentSearches',
        jsonEncode(recentSearches),
      );

  /// No-op for an out-of-range index: "move left" on the first tile and "move
  /// right" on the last are ordinary button presses.
  void moveTile(int from, int to) {
    final n = tiles.length;
    if (from < 0 || from >= n || to < 0 || to >= n) return;
    tiles.insert(to, tiles.removeAt(from));
  }

  void removeTileAt(int i) => tiles.removeAt(i);

  void addTile(AppTile t) => tiles.add(t);

  void setTileIcon(int i, String icon) =>
      tiles[i] = AppTile(tiles[i].package, icon);

  /// The content rows the home draws, in [homeRows] order: [items] by row
  /// key, without the rows switched off or empty.
  List<(String, List<MediaItem>)> shownRows(
    Map<String, List<MediaItem>> items,
  ) => [
    for (final r in homeRows)
      if (r.on)
        for (final row
            in r.key == 'games' && gamesBySport
                ? _bySport(items['games'] ?? const [])
                : [(r.key, items[r.key] ?? const <MediaItem>[])])
          if (row.$2.isNotEmpty) row,
  ];

  /// The games as `games:<sport>` rows, the sport of the first league
  /// followed first; each keeps the games' order.
  List<(String, List<MediaItem>)> _bySport(List<MediaItem> games) {
    final rows = <String, List<MediaItem>>{
      for (final f in sports) f.league.split('/').first: [],
    };
    for (final g in games) {
      (rows[g.game?.sport ?? ''] ??= []).add(g);
    }
    return [
      for (final MapEntry(:key, :value) in rows.entries) ('games:$key', value),
    ];
  }

  /// The row to draw: tiles whose app is installed, plus the pseudo tiles. The
  /// others stay in [tiles], so reinstalling an app brings its tile back.
  List<AppTile> visibleTiles(Set<String> installedPackages) => [
    for (final t in tiles)
      if (t.package.startsWith('ilonatv:') ||
          installedPackages.contains(t.package))
        t,
  ];
}

/// A random (version 4) UUID, as `java.util.UUID.randomUUID()` writes one.
String _uuid4() {
  final r = Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = b[6] & 0x0f | 0x40;
  b[8] = b[8] & 0x3f | 0x80;
  final h = [for (final x in b) x.toRadixString(16).padLeft(2, '0')].join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// 16 random bytes as 32 hex characters.
String randomHex([Random? random]) {
  final r = random ?? Random.secure();
  return [
    for (var i = 0; i < 16; i++)
      r.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
}
