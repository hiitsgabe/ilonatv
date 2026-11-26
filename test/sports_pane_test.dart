import 'dart:io';

import 'package:ilonatv/data/sports.dart';
import 'package:ilonatv/net.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/ui/settings_kit.dart';
import 'package:ilonatv/ui/sports_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsRow));

bool _focused(WidgetTester tester, String title) => Focus.of(
  tester.element(
    find.descendant(of: _row(title), matching: find.byType(Row)).first,
  ),
).hasPrimaryFocus;

String? _value(WidgetTester tester, String title) => tester
    .widget<SettingsRow>(
      find.ancestor(of: find.text(title), matching: find.byType(SettingsRow)),
    )
    .value;

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pumpAndSettle();
}

Future<Settings> _open(
  WidgetTester tester,
  Fetch fetch, [
  List<SportsFollow> sports = const [],
]) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final s = (await Settings.load())..sports = [...sports];
  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: s,
        builder: (_, _) => SettingsPage(
          title: 'Sports',
          icon: Icons.sports_soccer_outlined,
          child: SportsPane(s, fetch: fetch),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

Future<void> _openNba(WidgetTester tester) async {
  while (!_focused(tester, 'NBA')) {
    await _press(tester, LogicalKeyboardKey.arrowDown);
  }
  await _press(tester, LogicalKeyboardKey.enter);
}

void main() {
  testWidgets('a row per league with its value; OK opens the league: Follow, '
      'Only my teams, then its teams, each a check row; Back shows the '
      'value', (tester) async {
    final net = fake({'basketball/nba/teams': 'espn_teams_nba.json'});
    final s = await _open(tester, net.call);
    for (final (_, name) in kSportsLeagues) {
      expect(_value(tester, name), 'Off', reason: name);
    }
    await _openNba(tester);
    expect(net.calls.single.path, '/apis/site/v2/sports/basketball/nba/teams');
    expect(_focused(tester, 'Follow'), isTrue);
    expect(find.text('Only my teams'), findsNothing);
    expect(find.text('Boston Celtics'), findsOneWidget);

    await _press(tester, LogicalKeyboardKey.enter);
    expect(s.sports.single.league, 'basketball/nba');
    expect(s.sports.single.onlyTeams, isFalse);
    expect(_value(tester, 'Follow'), 'On');

    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Only my teams'), isTrue);
    await _press(tester, LogicalKeyboardKey.enter);
    expect(s.sports.single.onlyTeams, isTrue);

    // The teams, by name: the first is the Celtics, then the Nets.
    await _press(tester, LogicalKeyboardKey.arrowDown);
    expect(_focused(tester, 'Boston Celtics'), isTrue);
    await _press(tester, LogicalKeyboardKey.enter);
    await _press(tester, LogicalKeyboardKey.arrowDown);
    await _press(tester, LogicalKeyboardKey.enter);
    expect([for (final t in s.sports.single.teams) t.id], ['2', '17']);
    expect(
      find.descendant(
        of: _row('Boston Celtics'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    // OK again takes the team off.
    await _press(tester, LogicalKeyboardKey.enter);
    expect([for (final t in s.sports.single.teams) t.id], ['2']);
    expect(
      (await Settings.load()).sports.single.teams.single.name,
      'Boston Celtics',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(_value(tester, 'NBA'), '1 team');
  });

  testWidgets('Follow off and on keeps the teams; unticking the last one '
      'unfollows', (tester) async {
    final net = fake({'basketball/nba/teams': 'espn_teams_nba.json'});
    final s = await _open(tester, net.call);
    await _openNba(tester);
    Future<void> tap(String text) async {
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tap('Boston Celtics');
    expect(s.sports.single.onlyTeams, isTrue);
    await tap('Follow');
    expect(s.sports, isEmpty);
    await tap('Follow');
    expect([for (final t in s.sports.single.teams) t.id], ['2']);
    await tap('Boston Celtics');
    expect(s.sports, isEmpty);
  });

  testWidgets('teams that do not load say so, and Check again asks again', (
    tester,
  ) async {
    var fail = true;
    Future<Map<String, dynamic>> fetch(
      Uri uri, {
      Map<String, String> headers = const {},
    }) async {
      if (fail) throw const SocketException('offline');
      return fixture('espn_teams_nba.json');
    }

    await _open(tester, fetch);
    await _openNba(tester);
    expect(find.text('Network error'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Check again'));
    await tester.pumpAndSettle();
    expect(find.text('Network error'), findsNothing);
    expect(find.text('Orlando Magic'), findsOneWidget);
  });

  testWidgets('with $kMaxSportsLeagues leagues followed, another one is not: '
      'the page says why', (tester) async {
    final net = fake({'basketball/nba/teams': 'espn_teams_nba.json'});
    final s = await _open(tester, net.call, [
      for (var i = 0; i < kMaxSportsLeagues; i++)
        SportsFollow('soccer/x.$i', '$i'),
    ]);
    await _openNba(tester);
    expect(find.text('Up to 8 leagues: turn one off first.'), findsOneWidget);
    await _press(tester, LogicalKeyboardKey.enter);
    await tester.tap(find.text('Boston Celtics'));
    await tester.pumpAndSettle();
    expect(s.sports, hasLength(kMaxSportsLeagues));
    expect(s.sports.any((f) => f.league == 'basketball/nba'), isFalse);
  });
}
