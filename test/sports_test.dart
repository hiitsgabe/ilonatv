import 'dart:io';

import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/sports.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/net.dart';
import 'package:ilonatv/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// Before the Copa games of the fixture (19:00Z and 21:30Z), and the evening
/// before the NBA's last game (02:00Z the next day).
final _now = DateTime.utc(2026, 11, 1, 15);

const _utcMinus5 = Duration(hours: -5);
const _utcMinus3 = Duration(hours: -3);

MediaItem _game(
  String id, {
  required DateTime start,
  String state = 'pre',
  String home = '1',
  String away = '2',
  String league = 'soccer/bra.1',
}) => MediaItem(
  type: MediaType.game,
  id: id,
  title: id,
  game: Game(
    league: league,
    start: start,
    state: state,
    home: GameTeam(id: home, name: home, short: home, abbr: home),
    away: GameTeam(id: away, name: away, short: away, abbr: away),
  ),
);

List<String> _ids(List<MediaItem> items) => [for (final i in items) i.id];

/// Every game of the Copa, Grêmio's first; of the NBA only the Lakers'.
const _follows = [
  SportsFollow(
    'soccer/bra.copa_do_brazil',
    'Copa do Brasil',
    teams: [SportsTeam('6273', 'Grêmio')],
  ),
  SportsFollow(
    'basketball/nba',
    'NBA',
    onlyTeams: true,
    teams: [SportsTeam('13', 'Los Angeles Lakers')],
  ),
];

Future<Settings> _settings([List<SportsFollow> sports = _follows]) async {
  SharedPreferences.setMockInitialValues({});
  return (await Settings.load())..sports = [...sports];
}

/// The fixtures by request: the Copa on any day, the NBA on November 1st and
/// its teams; every other league has no games that day.
({Fetch call, List<Uri> calls}) _net({bool offline = false}) {
  final calls = <Uri>[];
  Future<Map<String, dynamic>> call(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    calls.add(uri);
    if (offline) throw const SocketException('offline');
    final path = uri.path;
    if (path.contains('bra.copa_do_brazil')) {
      return fixture('espn_scoreboard_copa.json');
    }
    if (path.endsWith('basketball/nba/teams')) {
      return fixture('espn_teams_nba.json');
    }
    if (path.contains('basketball/nba/scoreboard') &&
        uri.query == 'dates=20261101') {
      return fixture('espn_scoreboard_nba.json');
    }
    return {'events': []};
  }

  return (call: call, calls: calls);
}

bool _board(Uri u) => !u.path.contains('searchteams');

/// A [MemStore] whose entries read [age] older than they are.
class _AgedStore extends MemStore {
  Duration age = Duration.zero;

  @override
  Future<DateTime?> writtenAt(String name) async =>
      (await super.writtenAt(name))?.subtract(age);
}

void main() {
  tearDown(() => I18n.language = 'en');

  test('the ESPN scoreboard: both Copa games, home and away; the league '
      'has no abbreviation, so its name is the competition', () {
    final games = parseScoreboard(
      fixture('espn_scoreboard_copa.json'),
      'soccer/bra.copa_do_brazil',
    );
    expect(_ids(games), ['espn:401913105', 'espn:401913109']);
    final second = games[1];
    expect(second.type, MediaType.game);
    expect(second.title, 'Grêmio × Atlético-MG');
    expect(second.genre, 'Copa do Brasil');
    final g = second.game!;
    expect(g.start, DateTime.utc(2026, 11, 1, 21, 30));
    expect(g.state, 'pre');
    expect(g.sport, 'soccer');
    expect(
      [g.home.id, g.home.name, g.home.abbr, g.home.color],
      ['6273', 'Grêmio', 'GRE', '0093EC'],
    );
    expect(
      g.home.logo,
      'https://a.espncdn.com/i/teamlogos/soccer/500/6273.png',
    );
    expect([g.away.id, g.away.abbr], ['7632', 'CAM']);
  });

  test("an NBA day at ESPN: the league's abbreviation; with teams, only "
      'their games', () {
    final json = fixture('espn_scoreboard_nba.json');
    final all = parseScoreboard(json, 'basketball/nba');
    expect(all, hasLength(4));
    expect(all.first.genre, 'NBA');
    final games = parseScoreboard(json, 'basketball/nba', teams: {'13'});
    final g = games.single.game!;
    expect(games.single.id, 'espn:401909906');
    expect(games.single.title, 'Lakers × Raptors');
    expect(games.single.genre, 'NBA');
    expect(g.league, 'basketball/nba');
    expect(g.sport, 'basketball');
    expect(g.start, DateTime.utc(2026, 11, 2, 2));
    expect([g.home.abbr, g.away.abbr], ['LAL', 'TOR']);
    expect([g.away.id, g.away.color], ['28', 'd91244']);
    expect(
      g.away.logo,
      'https://a.espncdn.com/i/teamlogos/nba/500/scoreboard/tor.png',
    );
    expect(_ids(parseScoreboard(json, 'basketball/nba', teams: {'2', '17'})), [
      'espn:401909903',
      'espn:401909904',
    ]);
    expect(parseScoreboard(json, 'basketball/nba', teams: {}), isEmpty);
  });

  test("a league's teams at ESPN: by name, with their logos", () {
    final teams = parseTeams(fixture('espn_teams_nba.json'));
    expect(
      [for (final t in teams) (t.id, t.name, t.short, t.abbr)],
      [
        ('2', 'Boston Celtics', 'Celtics', 'BOS'),
        ('17', 'Brooklyn Nets', 'Nets', 'BKN'),
        ('13', 'Los Angeles Lakers', 'Lakers', 'LAL'),
        ('19', 'Orlando Magic', 'Magic', 'ORL'),
      ],
    );
    expect(
      teams.first.logo,
      'https://a.espncdn.com/i/teamlogos/nba/500/bos.png',
    );
  });

  test('favouriteKey: a soccer club is one team in every competition; other '
      "leagues' ids are their own", () {
    expect(
      favouriteKey('soccer/eng.1', '359'),
      favouriteKey('soccer/uefa.champions', '359'),
    );
    expect(
      favouriteKey('basketball/nba', '21'),
      isNot(favouriteKey('hockey/nhl', '21')),
    );
  });

  test('order: the favourites first, in their order and across leagues, '
      'then live, then by start; one game once', () {
    final at = DateTime.utc(2026, 11, 1, 20);
    final games = [
      _game('late', start: at.add(const Duration(hours: 2))),
      _game('early', start: at),
      _game('live', start: at.subtract(const Duration(hours: 1)), state: 'in'),
      _game('fav1', start: at.add(const Duration(hours: 3)), away: '7'),
      // The same club in a cup: still the favourite.
      _game(
        'fav1-cup',
        start: at.add(const Duration(hours: 4)),
        home: '7',
        league: 'soccer/bra.copa_do_brazil',
      ),
      _game(
        'fav0',
        start: at.add(const Duration(hours: 5)),
        home: '21',
        league: 'basketball/nba',
      ),
      // Id 21 of another league is another team.
      _game(
        'other-21',
        start: at.add(const Duration(hours: 1)),
        home: '21',
        league: 'hockey/nhl',
      ),
      _game('early', start: at),
      // At the same time as "early": by key.
      _game('a-early', start: at),
    ];
    final first = [
      favouriteKey('basketball/nba', '21'),
      favouriteKey('soccer/bra.1', '7'),
    ];
    expect(_ids(upcoming(games, _now, first: first, utcOffset: _utcMinus5)), [
      'fav0',
      'fav1',
      'fav1-cup',
      'live',
      'a-early',
      'early',
      'other-21',
      'late',
    ]);
    expect(_ids(upcoming(games, _now, utcOffset: _utcMinus5)), [
      'live',
      'a-early',
      'early',
      'other-21',
      'late',
      'fav1',
      'fav1-cup',
      'fav0',
    ]);
  });

  test('today and tomorrow by the local clock; finished ones stay until 5 h '
      'after their start, live ones 6 h', () {
    // 22:00 at UTC-5.
    final now = DateTime.utc(2026, 11, 2, 3);
    final games = [
      // 23:30 tonight at UTC-5, already tomorrow in UTC: today.
      _game('tonight', start: DateTime.utc(2026, 11, 2, 4, 30)),
      // 19:00 the day after tomorrow, at UTC-5.
      _game('later', start: DateTime.utc(2026, 11, 4)),
      _game('tomorrow', start: DateTime.utc(2026, 11, 2, 23)),
      // Started 6 h ago and over: gone. Started 4 h ago: still on.
      _game(
        'old',
        start: now.subtract(const Duration(hours: 6)),
        state: 'post',
      ),
      _game(
        'recent',
        start: now.subtract(const Duration(hours: 4)),
        state: 'post',
      ),
      // Live 5 h after its start: on. Still "live" after 7 h: stale, gone.
      _game(
        'overtime',
        start: now.subtract(const Duration(hours: 5)),
        state: 'in',
      ),
      _game(
        'stuck',
        start: now.subtract(const Duration(hours: 7)),
        state: 'in',
      ),
      // Earlier today but never started, so not live: still today's.
      _game('delayed', start: DateTime.utc(2026, 11, 1, 23)),
      _game('yesterday', start: DateTime.utc(2026, 11, 1, 3)),
    ];
    expect(_ids(upcoming(games, now, utcOffset: _utcMinus5)), [
      'overtime',
      // Both at 23:00Z: by key.
      'delayed',
      'recent',
      'tonight',
      'tomorrow',
    ]);
  });

  test('an ESPN game live, and one postponed, which is left out', () {
    final games = parseScoreboard(
      fixture('espn_scoreboard_live.json'),
      'soccer/bra.copa_do_brazil',
    );
    final g = games.single.game!;
    expect(games.single.id, 'espn:401913105');
    expect([g.state, g.live, g.detail], ['in', true, "67'"]);
    expect([g.home.score, g.away.score], ['2', '1']);
    expect(gameStatus(g, _now), "LIVE · 2–1 · 67'");
  });

  test('the card line: local time with the zone given, live, final; a later '
      "day in the language's order", () {
    final game = parseScoreboard(
      fixture('espn_scoreboard_copa.json'),
      'soccer/bra.copa_do_brazil',
    )[1].game!;
    expect(gameStatus(game, _now, utcOffset: _utcMinus3), 'Today 18:30');
    expect(gameStatus(game, _now, utcOffset: _utcMinus5), 'Today 16:30');
    // 23:00 at UTC-5 the evening before.
    final before = DateTime.utc(2026, 11, 1, 4);
    expect(gameStatus(game, before, utcOffset: _utcMinus5), 'Tomorrow 16:30');
    final weekBefore = DateTime.utc(2026, 10, 25, 12);
    expect(gameStatus(game, weekBefore, utcOffset: _utcMinus5), '11/1 16:30');
    I18n.language = 'pt';
    expect(gameStatus(game, before, utcOffset: _utcMinus5), 'Amanhã 16:30');
    expect(gameStatus(game, weekBefore, utcOffset: _utcMinus5), '1/11 16:30');
    final live = Game(
      league: game.league,
      start: game.start,
      state: 'in',
      detail: "67'",
      home: GameTeam(id: '1', name: 'A', short: 'A', abbr: 'A', score: '2'),
      away: GameTeam(id: '2', name: 'B', short: 'B', abbr: 'B', score: '1'),
    );
    expect(gameStatus(live, _now), "AO VIVO · 2–1 · 67'");
    final over = Game(
      league: live.league,
      start: live.start,
      state: 'post',
      home: live.home,
      away: live.away,
    );
    I18n.language = 'en';
    expect(gameStatus(over, _now), 'Final · 2–1');
  });

  test('a game survives the cache as JSON', () {
    final item = parseScoreboard(
      fixture('espn_scoreboard_copa.json'),
      'soccer/bra.copa_do_brazil',
    )[1];
    final back = MediaItem.fromJson(item.toJson());
    expect(back.toJson(), item.toJson());
    expect(back.game!.start, item.game!.start);
    expect(back.game!.start.isUtc, isTrue);
  });

  group('SportsSource', () {
    test('asks each followed league for yesterday, today and tomorrow; one '
        'row, the favourites first; cached', () async {
      final store = MemStore();
      final net = _net();
      final s = await _settings();
      final source = SportsSource(s, store, fetch: net.call, now: () => _now);
      var heard = 0;
      source.addListener(() => heard++);
      await source.refresh();
      final uris = [
        for (final u in net.calls)
          if (_board(u)) u.toString(),
      ];
      expect(uris, hasLength(_follows.length * 3));
      expect(uris, [
        for (final l in ['soccer/bra.copa_do_brazil', 'basketball/nba'])
          for (final d in ['20261031', '20261101', '20261102'])
            'https://site.api.espn.com/apis/site/v2/sports/$l/scoreboard?dates=$d',
      ]);
      // The Copa answers for every day: each game once. Grêmio's game, then
      // the Lakers', then the rest; of the NBA's day, only the Lakers'.
      expect(_ids(source.games), [
        'espn:401913109',
        'espn:401909906',
        'espn:401913105',
      ]);
      expect(heard, 1);

      // Young: a second refresh asks nothing; a new source reads the cache.
      await source.refresh();
      expect(net.calls.where(_board), hasLength(uris.length));
      final again = SportsSource(s, store, fetch: net.call, now: () => _now);
      await again.loadCache();
      expect(_ids(again.games), _ids(source.games));
    });

    test('no league followed: nothing asked, no row', () async {
      final net = _net();
      final source = SportsSource(
        await _settings(const []),
        MemStore(),
        fetch: net.call,
        now: () => _now,
      );
      await source.refresh();
      expect(net.calls, isEmpty);
      expect(source.games, isEmpty);
    });

    test('a change to the follows asks again at once; a league no longer '
        'followed leaves the row', () async {
      final net = _net();
      final s = await _settings(const []);
      final source = SportsSource(
        s,
        MemStore(),
        fetch: net.call,
        now: () => _now,
      );
      await source.refresh();
      s.sports = [_follows.first];
      await s.save();
      await pumpEventQueue();
      expect(net.calls.where(_board), hasLength(3));
      expect(_ids(source.games), ['espn:401913109', 'espn:401913105']);
      // Only the favourites changed: nothing is asked.
      s.sports = [
        const SportsFollow('soccer/bra.copa_do_brazil', 'Copa do Brasil'),
      ];
      await s.save();
      await pumpEventQueue();
      expect(net.calls.where(_board), hasLength(3));
      expect(_ids(source.games).toSet(), {'espn:401913109', 'espn:401913105'});
      s.sports = [_follows.last];
      await s.save();
      await pumpEventQueue();
      expect(net.calls.where(_board), hasLength(6));
      expect(_ids(source.games), ['espn:401909906']);
      // A save that changes no follow asks nothing.
      s.tmdbKey = 'k';
      await s.save();
      await pumpEventQueue();
      expect(net.calls.where(_board), hasLength(6));
    });

    test('at most $kMaxSportsLeagues leagues are asked', () async {
      final net = _net();
      final s = await _settings([
        for (var i = 0; i < kMaxSportsLeagues + 2; i++)
          SportsFollow('soccer/x.$i', '$i'),
      ]);
      await SportsSource(
        s,
        MemStore(),
        fetch: net.call,
        now: () => _now,
      ).refresh();
      expect(net.calls.where(_board), hasLength(kMaxSportsLeagues * 3));
    });

    test('offline: the row keeps what it had and the cache its age', () async {
      final store = MemStore();
      final s = await _settings();
      final first = SportsSource(s, store, fetch: _net().call, now: () => _now);
      await first.refresh();
      final at = await store.writtenAt('sports');

      final offline = _net(offline: true);
      final source = SportsSource(
        s,
        store,
        fetch: offline.call,
        now: () => _now,
      );
      await source.loadCache();
      await source.refresh(force: true);
      expect(offline.calls, isNotEmpty);
      expect(_ids(source.games), _ids(first.games));
      expect(await store.writtenAt('sports'), at);

      // Nothing cached and no network: no row, and no error.
      final none = SportsSource(
        s,
        MemStore(),
        fetch: offline.call,
        now: () => _now,
      );
      await none.refresh();
      expect(none.games, isEmpty);
    });

    test(
      'one league failing keeps its games; the others are replaced',
      () async {
        final store = MemStore();
        final s = await _settings();
        await SportsSource(
          s,
          store,
          fetch: _net().call,
          now: () => _now,
        ).refresh();
        final at = await store.writtenAt('sports');
        // The Copa fails now, and the NBA has no games left.
        Future<Map<String, dynamic>> fetch(
          Uri uri, {
          Map<String, String> headers = const {},
        }) async {
          if (uri.path.contains('copa')) throw const SocketException('down');
          return {'events': []};
        }

        final source = SportsSource(s, store, fetch: fetch, now: () => _now);
        await source.loadCache();
        await source.refresh(force: true);
        expect(_ids(source.games), ['espn:401913109', 'espn:401913105']);
        expect(await store.writtenAt('sports'), at);
      },
    );

    test('the tick just under 5 min after a write asks with a game on, not '
        'without; just under 30 min it asks anyway', () async {
      // On the real clock, as the cache's age is.
      final now = DateTime.now();
      final s = await _settings();
      Map<String, dynamic> cached(String state, Duration sinceStart) => {
        'games': [
          _game('g', start: now.subtract(sinceStart), state: state).toJson(),
        ],
      };
      Future<int> asked(Map<String, dynamic> cache, Duration age) async {
        final store = _AgedStore()..age = age;
        await store.write('sports', cache);
        final net = _net();
        final source = SportsSource(s, store, fetch: net.call);
        await source.loadCache();
        await source.refresh();
        return net.calls.where(_board).length;
      }

      const almost5 = Duration(minutes: 4, seconds: 50);
      const almost30 = Duration(minutes: 29, seconds: 50);
      const later = Duration(hours: -4);
      const all = 6;
      expect(await asked(cached('in', const Duration(hours: 1)), almost5), all);
      // Past its start but not yet seen live: on too.
      expect(
        await asked(cached('pre', const Duration(minutes: 10)), almost5),
        all,
      );
      // In play past 3 h (extra time, a delay): still on.
      expect(await asked(cached('in', const Duration(hours: 4)), almost5), all);
      expect(await asked(cached('pre', later), almost5), 0);
      expect(await asked(cached('post', const Duration(hours: 2)), almost5), 0);
      expect(await asked(cached('pre', later), almost30), all);
    });

    test(
      'each game gets its home team photo, else the away team\'s, from '
      'TheSportsDB by a name the team goes by; kept for the next run',
      () async {
        final store = MemStore();
        final s = await _settings();
        final asked = <String>[];
        Future<Map<String, dynamic>> fetch(
          Uri u, {
          Map<String, String> headers = const {},
        }) async {
          if (_board(u)) return _net().call(u);
          final t = u.queryParameters['t']!;
          asked.add(t);
          return switch (t) {
            // A near name finds another club: not it.
            'atletico mg' => {
              'teams': [
                {'strTeam': 'ATK', 'strSport': 'Soccer', 'strFanart1': 'X'},
              ],
            },
            'atletico mineiro' => {
              'teams': [
                {
                  'strTeam': 'Atlético Mineiro',
                  'strSport': 'Soccer',
                  'strFanart1': 'https://x/cam.jpg',
                },
              ],
            },
            _ => {'teams': null},
          };
        }

        final source = SportsSource(s, store, fetch: fetch, now: () => _now);
        await source.refresh();
        await pumpEventQueue();
        // Grêmio (home) has none: the away side's.
        final first = source.games.first;
        expect(first.title, 'Grêmio × Atlético-MG');
        expect(first.backdropUrl, 'https://x/cam.jpg');
        expect(asked, containsAllInOrder(['atletico mg', 'atletico mineiro']));
        // Kept: a new run shows it with no lookup.
        final again = SportsSource(s, store, fetch: fetch, now: () => _now);
        asked.clear();
        await again.loadCache();
        expect(again.games.first.backdropUrl, 'https://x/cam.jpg');
        expect(asked, isEmpty);
      },
    );

    test('a cache that does not read is skipped; so is the two rows\' cache '
        'of before', () async {
      final s = await _settings();
      for (final bad in [
        {'games': 'nope'},
        {'brazil': [], 'toronto': []},
      ]) {
        final store = MemStore();
        await store.write('sports', bad);
        final source = SportsSource(
          s,
          store,
          fetch: _net().call,
          now: () => _now,
        );
        await source.loadCache();
        expect(source.games, isEmpty);
      }
    });

    test("the assistant finds a team that is not in the row among a followed "
        "league's teams, and asks for its schedule", () async {
      final net = _net();
      final source = SportsSource(
        await _settings([const SportsFollow('basketball/nba', 'NBA')]),
        MemStore(),
        fetch: net.call,
        now: () => _now,
      );
      expect(await source.assistantGames('Celtics', 'next'), isEmpty);
      expect(
        [for (final u in net.calls) u.path],
        [
          '/apis/site/v2/sports/basketball/nba/teams',
          '/apis/site/v2/sports/basketball/nba/teams/2/schedule',
        ],
      );
      // A team of no followed league is not looked for anywhere else.
      net.calls.clear();
      expect(await source.assistantGames('Flamengo', 'next'), isEmpty);
      expect(net.calls, isEmpty);
    });
  });
  group('team names in other texts', () {
    const cam = GameTeam(
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
    const leafs = GameTeam(
      id: '21',
      name: 'Toronto Maple Leafs',
      short: 'Maple Leafs',
      abbr: 'TOR',
    );

    test('plainName: lower case, no accents, other characters one space', () {
      expect(plainName('Atlético-MG'), 'atletico mg');
      expect(plainName('  São Paulo FC '), 'sao paulo fc');
      expect(plainName('GRÊMIO'), 'gremio');
      expect(plainName('Como | 06:30 | Venezia'), 'como 06 30 venezia');
    });

    GameTeam team(String name, String abbr, [String? short]) =>
        GameTeam(id: abbr, name: name, short: short ?? name, abbr: abbr);
    Game game(GameTeam home, GameTeam away) => Game(
      league: 'soccer/bra.1',
      start: DateTime.utc(2026, 11, 1, 19),
      state: 'pre',
      home: home,
      away: away,
    );

    test('plainName drops every accent NFD splits off, as Kotlin does', () {
      expect(plainName('Łódź Ñuñoa Ğ Çorum Škoda'), 'odz nunoa g corum skoda');
      // Already apart: an "e" and a combining acute; a capital dotted I.
      expect(plainName('Gre\u0301mio İstanbul'), 'gremio istanbul');
    });

    test('teamNames: names and nicknames, once each; no abbreviation', () {
      expect(teamNames(cam), ['atletico mg', 'atletico mineiro', 'galo']);
      expect(teamNames(gremio), ['gremio']);
      expect(teamNames(leafs), contains('leafs'));
    });

    test('mentions: whole words, any accent, any case', () {
      final g = teamNames(cam);
      expect(mentions('Grêmio x Atlético Mineiro', g), isTrue);
      expect(mentions('ATLETICO-MG', g), isTrue);
      expect(mentions('Galo enfrenta o Grêmio', g), isTrue);
      expect(mentions('Atlético-GO x Grêmio', g), isFalse);
      expect(mentions('Athletico-PR x Grêmio', g), isFalse);
      expect(mentions('Campeonato Mineiro', g), isFalse);
      expect(mentions('Leafs at Canadiens', teamNames(leafs)), isTrue);
    });

    test('namesGame: both teams in one field, one at least by name', () {
      final gremioCam = game(gremio, cam);
      expect(namesGame('Grêmio x Atlético Mineiro', gremioCam), isTrue);
      expect(namesGame('GRE x Galo', gremioCam), isTrue);
      expect(namesGame('GRE x CAM', gremioCam), isFalse);
      expect(namesGame('Athletico-PR x Grêmio', gremioCam), isFalse);
      final raptors = team('Toronto Raptors', 'TOR', 'Raptors');
      final celtics = team('Boston Celtics', 'BOS', 'Celtics');
      expect(namesGame('NHL: BOS @ TOR', game(raptors, celtics)), isFalse);
      expect(namesGame('NBA: BOS @ Raptors', game(raptors, celtics)), isTrue);
      // An abbreviation counts in capitals only.
      final santos = team('Santos', 'SAN');
      final palmeiras = team('Palmeiras', 'PAL');
      expect(
        namesGame('San Lorenzo x Palmeiras', game(santos, palmeiras)),
        isFalse,
      );
      expect(namesGame('SAN x Palmeiras', game(santos, palmeiras)), isTrue);
      // All caps says nothing of abbreviations: names only.
      final bragantino = team('Bragantino', 'BRA');
      final santosBra = game(bragantino, santos);
      expect(namesGame('BRA | SANTOS X PALMEIRAS', santosBra), isFalse);
      expect(namesGame('BRAGANTINO X SANTOS', santosBra), isTrue);
    });
  });
}
