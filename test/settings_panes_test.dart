import 'dart:io';

import 'package:ilonatv/app.dart';
import 'package:ilonatv/companion/pairing.dart';
import 'package:ilonatv/data/sports.dart';
import 'package:ilonatv/data/stremio.dart';
import 'package:ilonatv/data/tmdb.dart';
import 'package:ilonatv/data/weather.dart';
import 'package:ilonatv/data/youtube.dart';
import 'package:ilonatv/data/youtube_tv.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/sources.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/launcher_setup.dart';
import 'package:ilonatv/ui/qr_code.dart';
import 'package:ilonatv/ui/settings_kit.dart';
import 'package:ilonatv/ui/settings_panes.dart';
import 'package:ilonatv/ui/settings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// The Accounts pane, offline: YouTube answers nothing.
Future<(Settings, Sources)> _pane(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  final settings = await Settings.load();
  final store = MemStore();
  Future<String> offline(Uri _, {Map<String, String> headers = const {}}) =>
      Future.error(const SocketException('offline'));
  final sources = Sources(
    weather: WeatherSource(settings, store, fetch: fake({}).call),
    tmdb: TmdbSource(
      settings,
      store,
      fetch: fake({}).call,
      post: fakePost({}).call,
    ),
    stremio: StremioSource(
      settings,
      store,
      client: StremioClient(post: fakePost({}).call),
    ),
    youtube: YoutubeSource(
      settings,
      store,
      YoutubeTvClient(store: store, post: fakePost({}).call, getText: offline),
    ),
    sports: SportsSource(settings, store, fetch: fake({}).call),
  );
  return (settings, sources);
}

Future<void> _show(WidgetTester tester, Settings s, Sources sources) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: YoutubePane(s, sources.youtube, sources.youtubeSignIn),
          ),
        ),
      ),
    );

void main() {
  test('maskKey shows the last four, and nothing of a short key', () {
    expect(maskKey('abcdefgh1234'), '••••••••1234');
    expect(maskKey('abcde'), '•bcde');
    expect(maskKey('abcd'), '••••');
    expect(maskKey('ab'), '••');
    expect(maskKey(''), '');
  });

  testWidgets('the code shows big, with the address without its scheme', (
    tester,
  ) async {
    final (s, sources) = await _pane(tester);
    sources.youtubeSignIn.code = const YtDeviceCode(
      deviceCode: 'DEVICE',
      userCode: 'ABC-DEF-GHIJ',
      verificationUrl: 'https://www.google.com/device',
      interval: 5,
      expiresIn: 1800,
    );
    await _show(tester, s, sources);
    expect(find.text('ABC-DEF-GHIJ'), findsOneWidget);
    expect(find.textContaining(' google.com/device '), findsOneWidget);
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('No account'), findsOneWidget);
  });

  testWidgets('the profiles start ticked; Add keeps the ticked ones', (
    tester,
  ) async {
    final (s, sources) = await _pane(tester);
    sources.youtubeSignIn.choices = const [
      YtAccount(refreshToken: 'REFRESH', name: 'Alex'),
      YtAccount(refreshToken: 'REFRESH', name: 'Kids', pageId: 'PAGE'),
    ];
    await _show(tester, s, sources);
    expect(find.byIcon(Icons.check), findsNWidgets(2));
    await tester.tap(find.text('Alex'));
    await tester.pump();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();

    expect(s.youtubeAccounts.map((a) => a.name), ['Kids']);
    expect(find.text('1 profile on'), findsOneWidget);
    expect(find.text('Add account'), findsOneWidget);

    // OK on the profile turns it off, and Remove takes it away.
    await tester.tap(find.text('On'));
    await tester.pumpAndSettle();
    expect(s.youtubeAccounts.single.enabled, isFalse);
    expect(find.text('0 profiles on'), findsOneWidget);
    await tester.tap(find.bySemanticsLabel('Remove'));
    await tester.pumpAndSettle();
    expect(s.youtubeAccounts, isEmpty);
    expect(find.text('No account'), findsOneWidget);
  });

  testWidgets('leaving the pane or the app going away ends the sign-in', (
    tester,
  ) async {
    final (s, sources) = await _pane(tester);
    const code = YtDeviceCode(
      deviceCode: 'DEVICE',
      userCode: 'ABC-DEF-GHIJ',
      verificationUrl: 'https://www.google.com/device',
      interval: 5,
      expiresIn: 1800,
    );
    final signIn = sources.youtubeSignIn
      ..code = code
      ..error = 'network';
    await _show(tester, s, sources);
    await tester.pumpWidget(const SizedBox());
    expect(signIn.code, isNull);
    expect(signIn.error, isNull);

    signIn.code = code;
    await _show(tester, s, sources);
    expect(find.text('ABC-DEF-GHIJ'), findsOneWidget);
    sources.stop();
    await tester.pump();
    expect(signIn.code, isNull);
    expect(find.text('Add account'), findsOneWidget);
  });

  testWidgets('Home rows: switch, move with focus following, and the '
      'app row editor that Back closes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = await Settings.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: RowsPane(s, const {})),
        ),
      ),
    );
    List<String> labels() => [
      for (final w in tester.widgetList<Text>(
        find.descendant(of: find.byType(Row), matching: find.byType(Text)),
      ))
        if (kHomeRows.contains(_key(w.data))) _key(w.data)!,
    ];
    expect(labels(), kHomeRows);

    // OK on the first content row turns it off.
    Finder value(String row) => find.descendant(
      of: find.ancestor(of: find.text(row), matching: find.byType(SettingsRow)),
      matching: find.byType(Text),
    );
    expect(tester.widget<Text>(value('Inputs').last).data, 'On');
    await tester.tap(find.text('Inputs'));
    await tester.pumpAndSettle();
    expect(s.homeRows.first, (key: 'inputs', on: false));
    expect(tester.widget<Text>(value('Inputs').last).data, 'Off');
    expect((await Settings.load()).homeRows.first, (key: 'inputs', on: false));

    // Move down from the first row twice; focus stays on its down button.
    await tester.tap(find.byIcon(Icons.arrow_downward).first);
    await tester.pumpAndSettle();
    expect(s.homeRows[1].key, 'inputs');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.homeRows[2].key, 'inputs');
    expect(labels()[2], 'inputs');

    await tester.tap(find.text('App row'));
    await tester.pumpAndSettle();
    expect(find.text('Choose icon'), findsWidgets);
    // The editor's first button has focus, not just its page.
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Choose icon'), findsNothing);
    expect(find.byType(RowsPane), findsOneWidget);
  });

  testWidgets('the root lists the twelve sections with their values, all on '
      'a Fire TV screen; the tile shows the focused one', (tester) async {
    final s = await _screen(tester);
    final screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final on = s.homeRows.where((r) => r.on).length;
    for (final (title, value) in [
      ('Home rows', '$on on'),
      ('Weather', s.weatherCity),
      ('Sports', 'Off'),
      ('Apps', null),
      ('Open with', null),
      ('Processes', null),
      ('Accounts', '0'),
      ('Companion', '0'),
      ('Launcher mode', 'Off'),
      ('Language', 'English'),
      ('TV settings', null),
      ('About', kVersion),
    ]) {
      final row = _row(title);
      expect(row, findsOneWidget, reason: title);
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(screen.height));
      if (value != null) {
        expect(
          find.descendant(of: row, matching: find.text(value)),
          findsOneWidget,
          reason: title,
        );
      }
    }
    final list = tester.state<ScrollableState>(find.byType(Scrollable).first);
    expect(list.position.maxScrollExtent, 0);
    expect(find.byIcon(Icons.view_agenda_outlined), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.wb_sunny_outlined), findsOneWidget);
  });

  testWidgets('OK opens a section on a screen of its own, under its name; '
      'Back comes back to it', (tester) async {
    await _screen(tester);
    expect(_focused(tester, 'Home rows'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(RowsPane), findsOneWidget);
    expect(find.text('Home rows'), findsOneWidget);
    expect(find.text('Settings'), findsNothing);
    // The first row has focus.
    expect(_focused(tester, 'App row'), isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Settings'), findsOneWidget);
    expect(_focused(tester, 'Home rows'), isTrue);
  });

  testWidgets('Companion shows the QR of the TV\'s address', (tester) async {
    final ip = deviceIp;
    deviceIp = () async => '10.0.0.7';
    addTearDown(() => deviceIp = ip);
    await _screen(tester);
    await tester.tap(find.text('Companion'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<QrCode>(find.byType(QrCode)).data,
      startsWith('http://10.0.0.7:8642/#s='),
    );
  });

  testWidgets('About names the licence and credits TMDB and JustWatch', (
    tester,
  ) async {
    await _screen(tester);
    await tester.tap(find.text('About'));
    await tester.pumpAndSettle();
    expect(find.text('GPL-3.0-only'), findsOneWidget);
    expect(
      find.textContaining(
        'This product uses TMDB and the TMDB APIs but is not endorsed, '
        'certified, or otherwise approved by TMDB.',
      ),
      findsOneWidget,
    );
    expect(find.bySemanticsLabel('TMDB'), findsOneWidget);
    expect(find.textContaining('JustWatch'), findsOneWidget);
  });

  testWidgets('Weather: the city picked sets the country', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = (await Settings.load())..country = 'CA';
    final net = fake({
      '/v1/search': 'open_meteo_geocoding.json',
      '/v1/forecast': 'open_meteo_forecast.json',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: WeatherPane(
              s,
              WeatherSource(s, MemStore(), fetch: net.call),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('City'));
    await tester.pumpAndSettle();
    // OK on the focused field makes it editable, as on the TV.
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'Paris');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Texas, United States'));
    await tester.pumpAndSettle();
    expect(
      (s.weatherCity, s.weatherLat, s.weatherLon, s.country),
      ('Paris', 33.66094, -95.55551, 'US'),
    );
  });

  testWidgets('Weather: OK on the unit switches it and asks the forecast '
      'again in it', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final s = (await Settings.load())
      ..weatherCity = 'Paris'
      ..fahrenheit = false;
    final net = fake({'/v1/forecast': 'open_meteo_forecast.json'});
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WeatherPane(s, WeatherSource(s, MemStore(), fetch: net.call)),
        ),
      ),
    );
    expect(find.text('°C'), findsOneWidget);
    await tester.tap(find.text('Temperature unit'));
    await tester.pumpAndSettle();
    expect(find.text('°F'), findsOneWidget);
    expect(
      (await SharedPreferences.getInstance()).getBool('fahrenheit'),
      isTrue,
    );
    expect(net.calls.last.queryParameters['temperature_unit'], 'fahrenheit');
  });

  testWidgets('Language: a row per language, a check on the current one; OK '
      'on the other switches', (tester) async {
    addTearDown(() => I18n.language = 'en');
    final s = await _screen(tester);
    while (!_focused(tester, 'Language')) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _row('English'), matching: find.byIcon(Icons.check)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row('Português'),
        matching: find.byIcon(Icons.check),
      ),
      findsNothing,
    );
    // The first row has focus; OK on the current one does nothing.
    expect(_focused(tester, 'English'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.language, 'en');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.language, 'pt');
    expect(I18n.language, 'pt');
    // The screen's name, and the root under it, in the new language.
    expect(find.text('Idioma'), findsOneWidget);
    expect(
      find.descendant(
        of: _row('Português'),
        matching: find.byIcon(Icons.check),
      ),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Ajustes'), findsOneWidget);
    expect(
      find.descendant(of: _row('Idioma'), matching: find.text('Português')),
      findsOneWidget,
    );
  });
}

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsRow));

/// Whether the row [title] has focus.
bool _focused(WidgetTester tester, String title) => Focus.of(
  tester.element(
    find.descendant(of: _row(title), matching: find.byType(Row)).first,
  ),
).hasPrimaryFocus;

/// The Settings screen on a Fire TV's screen, offline, with no platform.
Future<Settings> _screen(WidgetTester tester) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  // A platform that answers nothing: no apps.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('tv.ilona/host'),
        (_) async => null,
      );
  final (s, sources) = await _pane(tester);
  await tester.pumpWidget(
    MaterialApp(home: SettingsScreen(s, sources, pairing: Pairing(s))),
  );
  await tester.pumpAndSettle();
  return s;
}

/// The row key whose English name is [text].
String? _key(String? text) => const {
  'Inputs': 'inputs',
  'Continue watching': 'continueWatching',
  'YouTube · Continue watching': 'youtubeContinue',
  'Trending · Movies': 'trendingMovies',
  'Trending · Series': 'trendingSeries',
  'Recommended': 'recommended',
  'YouTube': 'youtube',
  'Games': 'games',
}[text];
