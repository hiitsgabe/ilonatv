import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../i18n.dart';
import '../net.dart';
import '../settings.dart';
import '../store.dart';
import 'media.dart';

const _cache = 'sports';

/// Team photos found on TheSportsDB, by [_artKey]; kept for good.
const _artCache = 'team_art';

/// TheSportsDB's sport for an ESPN one.
const _sportsDbSport = {
  'soccer': 'Soccer',
  'basketball': 'Basketball',
  'hockey': 'Ice Hockey',
  'baseball': 'Baseball',
};

/// The leagues offered in Settings, by ESPN path. Each answered ESPN's
/// scoreboard and teams on 2026-11-25; only sports whose games have a home
/// and an away side.
const kSportsLeagues = [
  ('soccer/eng.1', 'English Premier League'),
  ('soccer/esp.1', 'Spanish LALIGA'),
  ('soccer/ita.1', 'Italian Serie A'),
  ('soccer/ger.1', 'German Bundesliga'),
  ('soccer/fra.1', 'French Ligue 1'),
  ('soccer/por.1', 'Portuguese Primeira Liga'),
  ('soccer/ned.1', 'Dutch Eredivisie'),
  ('soccer/sco.1', 'Scottish Premiership'),
  ('soccer/tur.1', 'Turkish Super Lig'),
  ('soccer/eng.2', 'English League Championship'),
  ('soccer/uefa.champions', 'UEFA Champions League'),
  ('soccer/uefa.europa', 'UEFA Europa League'),
  ('soccer/usa.1', 'MLS'),
  ('soccer/mex.1', 'Mexican Liga BBVA MX'),
  ('soccer/bra.1', 'Brazilian Serie A'),
  ('soccer/arg.1', 'Argentine Liga Profesional de Fútbol'),
  ('soccer/conmebol.libertadores', 'CONMEBOL Libertadores'),
  ('soccer/conmebol.sudamericana', 'CONMEBOL Sudamericana'),
  ('basketball/nba', 'NBA'),
  ('basketball/wnba', 'WNBA'),
  ('football/nfl', 'NFL'),
  ('hockey/nhl', 'NHL'),
  ('baseball/mlb', 'MLB'),
];

/// One day of a league ([league] is the path, `soccer/eng.1`): ESPN takes one
/// date per request (a range is a 400).
Uri scoreboardUri(String league, DateTime day) => Uri.parse(
  'https://site.api.espn.com/apis/site/v2/sports/$league/scoreboard'
  '?dates=${day.year}${_two(day.month)}${_two(day.day)}',
);

String _two(int n) => n.toString().padLeft(2, '0');

/// A team's coming games; without `fixture=true` ESPN's soccer schedule is
/// the results so far.
Uri scheduleUri(String league, String teamId) => Uri.parse(
  'https://site.api.espn.com/apis/site/v2/sports/$league/teams/$teamId/schedule'
  '?fixture=true',
);

/// The teams of a league, with their ids, names and logos.
Uri teamsUri(String league) =>
    Uri.parse('https://site.api.espn.com/apis/site/v2/sports/$league/teams');

/// The teams of an ESPN `teams` answer, by name.
List<GameTeam> parseTeams(Map<String, dynamic> json) {
  final teams = [
    for (final t
        in ((json['sports'] as List).first['leagues'] as List).first['teams']
            as List)
      if (t['team'] case final Map team)
        GameTeam(
          id: '${team['id']}',
          name: team['displayName'] as String,
          short:
              team['shortDisplayName'] as String? ??
              team['displayName'] as String,
          abbr: team['abbreviation'] as String? ?? '',
          logo: _str((team['logos'] as List?)?.firstOrNull?['href']),
          color: _str(team['color']),
        ),
  ];
  return teams..sort((a, b) => a.name.compareTo(b.name));
}

MediaItem _item(String id, Game g, String competition) => MediaItem(
  type: MediaType.game,
  id: id,
  title: '${g.home.short} × ${g.away.short}',
  genre: competition,
  game: g,
);

String? _str(Object? v) => v is String ? v : null;

/// An event of an ESPN scoreboard; none for one postponed or cancelled (over,
/// but not completed).
MediaItem? _espn(Map e, String league, String competition) {
  final c = (e['competitions'] as List).first as Map;
  final type = (e['status'] as Map)['type'] as Map;
  final state = type['state'] as String;
  if (state == 'post' && type['completed'] == false) return null;
  GameTeam side(String homeAway) {
    final t = (c['competitors'] as List).firstWhere(
      (t) => t['homeAway'] == homeAway,
    );
    final team = t['team'] as Map;
    final name = team['displayName'] as String;
    return GameTeam(
      id: '${team['id']}',
      name: name,
      short: team['shortDisplayName'] as String? ?? name,
      abbr: team['abbreviation'] as String? ?? '',
      logo: _str(team['logo']),
      color: _str(team['color']),
      score: t['score']?.toString(),
    );
  }

  return _item(
    'espn:${e['id']}',
    Game(
      league: league,
      start: DateTime.parse(e['date'] as String),
      state: state,
      detail: type['shortDetail'] as String? ?? '',
      home: side('home'),
      away: side('away'),
    ),
    competition,
  );
}

/// An event that does not read is left out, not the whole answer.
List<MediaItem> _each(List? events, MediaItem? Function(Map) read) => [
  for (final e in events ?? const []) ?_tryRead(e, read),
];

MediaItem? _tryRead(Object? e, MediaItem? Function(Map) read) {
  try {
    return read(e as Map);
  } catch (_) {
    return null;
  }
}

/// A day of an ESPN league; [league] is the path, `soccer/eng.1`. The
/// competition is the league's abbreviation, else its name; with [teams],
/// only the games of one of them.
List<MediaItem> parseScoreboard(
  Map<String, dynamic> json,
  String league, {
  Set<String>? teams,
}) {
  final l = (json['leagues'] as List?)?.firstOrNull as Map?;
  final name = _str(l?['abbreviation']) ?? _str(l?['name']) ?? '';
  return [
    for (final g in _each(
      json['events'] as List?,
      (e) => _espn(e, league, name),
    ))
      if (teams == null ||
          teams.contains(g.game!.home.id) ||
          teams.contains(g.game!.away.id))
        g,
  ];
}

/// [t]'s calendar day where the clock reads it: at [utcOffset], else in the
/// device's zone. A UTC midnight, so two of them differ by whole days.
DateTime _day(DateTime t, Duration? utcOffset) {
  final w = _wall(t, utcOffset);
  return DateTime.utc(w.year, w.month, w.day);
}

/// The wall clock at [t], as a UTC [DateTime] whose fields read like it.
DateTime _wall(DateTime t, Duration? utcOffset) =>
    t.toUtc().add(utcOffset ?? t.toLocal().timeZoneOffset);

/// About two hours of play, then three more on show.
// ponytail: ESPN does not say when a game ended; the start stands in.
const _shownAfterStart = Duration(hours: 5);

/// No game is live this long after its start: a source stuck on "in" is
/// stale.
const _liveAtMost = Duration(hours: 6);

/// The key of a team among the favourites: a club keeps its id across
/// soccer competitions, but other leagues reuse each other's ids.
String favouriteKey(String league, String teamId) =>
    '${league.startsWith('soccer/') ? 'soccer' : league}#$teamId';

/// Today's and tomorrow's games (by the clock at [utcOffset], else the
/// device's): live ones up to 6 h after their start, finished ones up to 5 h
/// (about 3 h after they ended). The games of the teams in [first]
/// ([favouriteKey]s) before all, in its order; then live, then by start, then
/// by key. One game once.
List<MediaItem> upcoming(
  Iterable<MediaItem> games,
  DateTime now, {
  List<String> first = const [],
  Duration? utcOffset,
}) {
  final today = _day(now, utcOffset);
  int dayOf(DateTime t) => _day(t, utcOffset).difference(today).inDays;
  bool shown(Game g) => switch (g.state) {
    'in' => now.isBefore(g.start.add(_liveAtMost)),
    'post' => now.isBefore(g.start.add(_shownAfterStart)),
    _ => const {0, 1}.contains(dayOf(g.start)),
  };
  final byKey = <String, MediaItem>{};
  for (final item in games) {
    if (item.game case final g? when shown(g)) {
      byKey.putIfAbsent(item.key, () => item);
    }
  }
  int favourite(Game g) {
    final i = [
      for (final t in [g.home, g.away])
        first.indexOf(favouriteKey(g.league, t.id)),
    ].where((i) => i >= 0);
    return i.isEmpty ? first.length : i.reduce(min);
  }

  return byKey.values.toList()..sort((a, b) {
    final (x, y) = (a.game!, b.game!);
    final f = favourite(x).compareTo(favourite(y));
    if (f != 0) return f;
    final l = (x.live ? 0 : 1).compareTo(y.live ? 0 : 1);
    if (l != 0) return l;
    final t = x.start.compareTo(y.start);
    return t != 0 ? t : a.key.compareTo(b.key);
  });
}

/// "Today 18:30", "Tomorrow 20:00"; "LIVE · 2–1 · 67'"; "Final · 2–1". Home
/// first, as in the title.
String gameStatus(Game g, DateTime now, {Duration? utcOffset}) {
  final score = '${g.home.score ?? 0}–${g.away.score ?? 0}';
  if (g.live) {
    return [t('live'), score, if (g.detail.isNotEmpty) g.detail].join(' · ');
  }
  if (g.state == 'post') return '${t('final')} · $score';
  final w = _wall(g.start, utcOffset);
  final time = '${_two(w.hour)}:${_two(w.minute)}';
  return switch (_day(
    g.start,
    utcOffset,
  ).difference(_day(now, utcOffset)).inDays) {
    0 => '${t('today')} $time',
    1 => '${t('tomorrow')} $time',
    _ =>
      '${I18n.language == 'pt' ? '${w.day}/${w.month}' : '${w.month}/${w.day}'}'
          ' $time',
  };
}

// The names of a team in someone else's text: a Stremio add-on's catalog.

/// The letters that Unicode's NFD splits into a base letter and marks, from
/// Latin-1 and Latin Extended-A; marks already apart ([_marks]) go too. A
/// letter NFD leaves whole (ø, ß, ł, đ) is "other".
const _accents = {
  'a': 'àáâãäåāăą',
  'c': 'çćĉċč',
  'd': 'ď',
  'e': 'èéêëēĕėęě',
  'g': 'ĝğġģ',
  'h': 'ĥ',
  'i': 'ìíîïĩīĭį',
  'j': 'ĵ',
  'k': 'ķ',
  'l': 'ĺļľ',
  'n': 'ñńņň',
  'o': 'òóôõöōŏő',
  'r': 'ŕŗř',
  's': 'śŝşš',
  't': 'ţť',
  'u': 'ùúûüũūŭůűų',
  'w': 'ŵ',
  'y': 'ýÿŷ',
  'z': 'źżž',
};
final _plain = {
  for (final MapEntry(:key, :value) in _accents.entries)
    for (final c in value.split('')) c: key,
};
final _marks = RegExp('[\u0300-\u036f]');
final _other = RegExp('[^a-z0-9]+');

/// [s] in lower case, without accents, every run of anything but letters and
/// digits one space: "Atlético-MG" is "atletico mg".
String plainName(String s) => s
    .toLowerCase()
    .split('')
    .map((c) => _plain[c] ?? c)
    .join()
    .replaceAll(_marks, '')
    .replaceAll(_other, ' ')
    .trim();

/// Nicknames the sources' names leave out, by [plainName].
// ponytail: add one when a game does not open where it should.
const _nicknames = {
  'atletico mg': ['atletico mineiro', 'galo'],
  'athletico pr': ['athletico paranaense', 'atletico paranaense'],
  'atletico go': ['atletico goianiense'],
  'red bull bragantino': ['bragantino'],
  'vasco da gama': ['vasco'],
  'sao paulo': ['spfc'],
  'maple leafs': ['leafs'],
  'toronto maple leafs': ['leafs'],
  'blue jays': ['jays'],
  'toronto blue jays': ['jays'],
};

/// The fanart of the first team of [sport] in a TheSportsDB `searchteams`
/// answer that one of [names] ([teamNames]) names; null when there is none.
/// A search finds near names too: "atletico mg" finds ATK.
String? teamArt(Map<String, dynamic> json, String? sport, List<String> names) {
  for (final t in json['teams'] as List? ?? const []) {
    if (t is Map &&
        t['strSport'] == sport &&
        [
          _str(t['strTeam']),
          ...?_str(t['strTeamAlternate'])?.split(','),
        ].nonNulls.any((n) => names.contains(plainName(n)))) {
      if (_str(t['strFanart1']) case final url? when url.isNotEmpty) {
        return url;
      }
    }
  }
  return null;
}

/// What a text may call [team] by, as [plainName]s: its name and short name,
/// and its known nicknames. Not the abbreviation: see [namesGame].
List<String> teamNames(GameTeam team) {
  final names = {
    for (final n in [team.name, team.short])
      if (plainName(n) case final p when p.isNotEmpty) p,
  };
  return {...names, for (final n in names) ...?_aliases[n]}.toList();
}

/// Every name of a [_nicknames] group, by each name in it: ESPN may say the
/// full name, a catalog the short one, a person the nickname.
final _aliases = {
  for (final MapEntry(:key, :value) in _nicknames.entries)
    for (final n in [key, ...value]) n: [key, ...value],
};

/// [text] names one of [terms] as whole words.
bool mentions(String text, List<String> terms) {
  final t = ' ${plainName(text)} ';
  return terms.any((term) => t.contains(' $term '));
}

/// [text] has [team]'s abbreviation (of 3 letters or more) as a whole word in
/// capitals: "SAN" of Santos is not the "San" of San Lorenzo. Text with no
/// lowercase letter at all is all caps, where capitals say nothing: names only.
bool _hasAbbr(String text, GameTeam team) =>
    team.abbr.length >= 3 &&
    text.contains(RegExp(r'\p{Ll}', unicode: true)) &&
    RegExp(
      '(?<![\\p{L}\\p{N}])${RegExp.escape(team.abbr.toUpperCase())}'
      '(?![\\p{L}\\p{N}])',
      unicode: true,
    ).hasMatch(text);

/// [text] (one field: a name, or a description) names both teams of [game],
/// at least one by a name ([teamNames]); the other may be its abbreviation.
/// "BOS @ TOR" is no game.
bool namesGame(String text, Game game) {
  final home = mentions(text, teamNames(game.home));
  final away = mentions(text, teamNames(game.away));
  return (home || away) &&
      (home || _hasAbbr(text, game.home)) &&
      (away || _hasAbbr(text, game.away));
}

/// Every 5 minutes while a game is on (in its first 3 h); else every 30.
// ponytail: the spec's 5 minutes are "with the row on screen"; here it is any
// live game while the app is in front (3 small requests a followed league).
// Tell the source which rows are on screen if that ever costs.
const _tick = Duration(minutes: 5);
const _calm = Duration(minutes: 30);

/// A tick comes just under its period after the write it follows: the cache
/// counts as due that much early.
const _slack = Duration(seconds: 30);

/// The home's games row: today's and tomorrow's games of the leagues followed
/// in Settings, the followed teams' first. Cached on disk, so the home opens
/// with them. A league that fails keeps its games of the last answer; the
/// others are replaced. A change to the follows asks again at once.
class SportsSource extends ChangeNotifier {
  final Settings settings;
  final Store store;
  final Fetch _fetch;
  final DateTime Function() _now;
  Timer? _timer;
  Future<void>? _refreshing;
  String _follows;

  List<MediaItem> games = [];

  SportsSource(
    this.settings,
    this.store, {
    this._fetch = getJson,
    this._now = DateTime.now,
  }) : _follows = '' {
    _follows = _asked;
    settings.addListener(_settingsChanged);
  }

  /// What a refresh asks ESPN for: the leagues and, of those with only
  /// their teams, the teams.
  String get _asked => jsonEncode([
    for (final f in _followed)
      [
        f.league,
        if (f.onlyTeams) [for (final t in f.teams) t.id],
      ],
  ]);

  void _settingsChanged() {
    final follows = _asked;
    if (follows == _follows) {
      // At most the favourites changed: the row reorders, nothing is asked.
      _show(games);
      return;
    }
    _follows = follows;
    // After one already running, which asked for the old follows.
    (_refreshing ?? Future<void>.value())
        .whenComplete(() => refresh(force: true))
        .ignore();
  }

  List<SportsFollow> get _followed =>
      settings.sports.take(kMaxSportsLeagues).toList();

  /// The followed teams, in the order of the follows and their teams.
  List<String> get _favourites => [
    for (final f in _followed)
      for (final t in f.teams) favouriteKey(f.league, t.id),
  ];

  /// For the voice assistant, as (item, isToday). [what] 'next': the coming
  /// games — a [team]'s from its ESPN schedule, else the row's (today and
  /// tomorrow). Otherwise today's games: everyone's, or the team's, and when
  /// the team has none today its next one, so "do they play today?" gets "no,
  /// next is Saturday" rather than nothing.
  Future<List<(MediaItem, bool)>> assistantGames(
    String team,
    String what,
  ) async {
    final now = _now();
    final today = _day(now, null);
    final all = [...games]
      ..sort((a, b) => a.game!.start.compareTo(b.game!.start));
    bool ofTeam(MediaItem i) =>
        team.isEmpty ||
        mentions(team, teamNames(i.game!.home)) ||
        mentions(team, teamNames(i.game!.away));
    bool isToday(MediaItem i) => _day(i.game!.start, null) == today;
    final mine = all.where(ofTeam).toList();
    if (what == 'next') {
      final coming = team.isEmpty
          ? mine.where((i) => i.game!.start.isAfter(now)).toList()
          : await nextGames(team, mine);
      return [for (final i in coming) (i, isToday(i))];
    }
    final todays = mine.where(isToday).toList();
    if (todays.isNotEmpty || team.isEmpty) {
      return [for (final i in todays) (i, true)];
    }
    final next = (await nextGames(team, mine)).firstOrNull;
    return [if (next != null) (next, false)];
  }

  /// [team]'s coming games, soonest first: the ones in [known] (the row's),
  /// else from its ESPN schedule. The team is found by name among the row's
  /// teams, else the followed leagues'. Nothing when it is not found or the
  /// ask fails.
  // ponytail: a schedule outside soccer is the whole season (some 800 KB for
  // an NBA team); asked only when the row has none of the team's games.
  Future<List<MediaItem>> nextGames(String team, List<MediaItem> known) async {
    final now = _now();
    final fromRows = known.where((i) => i.game!.start.isAfter(now)).toList();
    if (fromRows.isNotEmpty) return fromRows;
    try {
      final found = await _findTeam(team);
      if (found == null) return const [];
      final (league, id) = found;
      final json = await _fetch(scheduleUri(league, id));
      final games = _each(json['events'] as List?, (e) {
        // A schedule event keeps its status in the competition, not on itself.
        final c = (e['competitions'] as List).first as Map;
        final l = e['league'] as Map?;
        final name = _str(l?['abbreviation']) ?? _str(l?['name']) ?? '';
        return _espn({...e, 'status': c['status']}, league, name);
      });
      return games.where((i) => i.game!.start.isAfter(now)).toList()
        ..sort((a, b) => a.game!.start.compareTo(b.game!.start));
    } catch (e) {
      debugPrint('next games $team: $e');
      return const [];
    }
  }

  /// The league path and ESPN id of the team named [team]: one of the row's
  /// teams, else one of a followed league's (each league asked once per run).
  Future<(String, String)?> _findTeam(String team) async {
    for (final i in games) {
      final g = i.game!;
      for (final t in [g.home, g.away]) {
        if (mentions(team, teamNames(t))) return (g.league, t.id);
      }
    }
    for (final f in _followed) {
      final teams = _teams[f.league] ??= parseTeams(
        await _fetch(teamsUri(f.league)),
      );
      for (final t in teams) {
        if (mentions(team, teamNames(t))) return (f.league, t.id);
      }
    }
    return null;
  }

  final _teams = <String, List<GameTeam>>{};

  /// A game on, or due to be: one in play (the 6 h cap of [upcoming] bounds a
  /// stuck state), or past its start in the first 3 h and not over (one past
  /// its start still reads `pre` until it is asked again).
  bool get _live {
    final now = _now();
    return games.any((i) {
      final g = i.game!;
      return g.state == 'in' ||
          (g.state == 'pre' &&
              !now.isBefore(g.start) &&
              now.isBefore(g.start.add(const Duration(hours: 3))));
    });
  }

  /// Team photos by [_artKey]: a TheSportsDB fanart, or null for a team it
  /// has none for (asked again on the next run, not kept).
  final _art = <String, String?>{};

  static String _artKey(Game g, GameTeam t) => '${g.sport}/${t.name}';

  /// [i] with the home team's photo as its backdrop, else the away team's.
  MediaItem _withArt(MediaItem i) {
    final g = i.game!;
    final url = _art[_artKey(g, g.home)] ?? _art[_artKey(g, g.away)];
    return url == null || url == i.backdropUrl
        ? i
        : MediaItem(
            type: i.type,
            id: i.id,
            title: i.title,
            genre: i.genre,
            backdropUrl: url,
            game: g,
          );
  }

  /// Looks up, once per run, the photo of each team in the row that has none
  /// yet: TheSportsDB by each name [teamNames] knows, the first team of the
  /// game's sport with a fanart. Shows them as they come.
  Future<void> _findArt() async {
    final teams = {
      for (final i in games)
        for (final t in [i.game!.home, i.game!.away])
          if (!_art.containsKey(_artKey(i.game!, t)))
            _artKey(i.game!, t): (i.game!.sport, t),
    };
    if (teams.isEmpty) return;
    for (final MapEntry(:key, value: (sport, team)) in teams.entries) {
      _art[key] = null; // asked: not again this run
      final names = teamNames(team);
      for (final name in names) {
        try {
          final json = await _fetch(
            Uri.https(
              'www.thesportsdb.com',
              '/api/v1/json/123/searchteams.php',
              {'t': name},
            ),
          );
          final url = teamArt(json, _sportsDbSport[sport], names);
          if (url != null) {
            _art[key] = url;
            break;
          }
        } catch (_) {
          break; // ponytail: offline or refused; the next run asks again
        }
      }
    }
    try {
      await store.write(_artCache, {
        for (final e in _art.entries)
          if (e.value != null) e.key: e.value,
      });
    } catch (_) {}
    _show(games);
  }

  /// Drops what is no longer today's, tomorrow's or recent, puts the followed
  /// teams first, and gives each game its team photo when known; notifies when
  /// that changes the row.
  void _show(List<MediaItem> g) {
    g = upcoming(g, _now(), first: _favourites).map(_withArt).toList();
    if (listEquals(
      [for (final i in g) i.toJson().toString()],
      [for (final i in games) i.toJson().toString()],
    )) {
      return;
    }
    games = g;
    notifyListeners();
  }

  /// What the last run cached, of any age, less what is over by now. A cache
  /// this version cannot read is skipped.
  Future<void> loadCache() async {
    try {
      final art = await store.read(_artCache);
      if (art != null) _art.addAll(art.cast<String, String?>());
    } catch (_) {}
    try {
      final cached = await store.read(_cache);
      if (cached == null) return;
      _show([for (final j in cached['games'] as List) MediaItem.fromJson(j)]);
    } catch (_) {}
  }

  /// Asks ESPN, unless the cache is under 30 minutes old (5 with a game on),
  /// less [_slack]; [force] asks anyway. One asked while another runs gets
  /// that one.
  Future<void> refresh({bool force = false}) =>
      _refreshing ??= _refresh(force).whenComplete(() => _refreshing = null);

  Future<void> _refresh(bool force) async {
    _show(games);
    try {
      if (!force &&
          await store.freshOrNull(_cache, (_live ? _tick : _calm) - _slack) !=
              null) {
        return;
      }
    } catch (_) {}
    final now = _now();
    // Yesterday only for a game still live past midnight: what ended more
    // than 3 h ago is dropped as today's is.
    final days = [
      for (final k in [-1, 0, 1]) DateTime(now.year, now.month, now.day + k),
    ];
    final followed = _followed;
    final failed = <String>{};
    // ponytail: the requests go out at once, and a failed league is asked
    // again on the next tick with no back-off; batch them, and back off, if
    // ESPN ever starts refusing.
    Future<List<MediaItem>> ask(SportsFollow f, DateTime day) async {
      try {
        return parseScoreboard(
          await _fetch(scoreboardUri(f.league, day)),
          f.league,
          teams: f.onlyTeams ? {for (final t in f.teams) t.id} : null,
        );
      } catch (_) {
        failed.add(f.league);
        return const [];
      }
    }

    final answers = await Future.wait([
      for (final f in followed)
        for (final d in days) ask(f, d),
    ]);
    _show([
      ...answers.expand((a) => a),
      for (final g in games)
        if (failed.contains(g.game!.league)) g,
    ]);
    _findArt().ignore();
    // Only a full answer renews the cache's age: with a league missing, the
    // next tick asks again.
    if (failed.isNotEmpty) return;
    try {
      await store.write(_cache, {
        'games': [for (final i in games) i.toJson()],
      });
    } catch (_) {}
  }

  /// Refreshes at once, if due, and every 5 minutes after, which asks only
  /// when the cache is due. Safe to call again.
  void start() {
    refresh();
    _timer ??= Timer.periodic(_tick, (_) => refresh());
  }

  /// Safe without a [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}
