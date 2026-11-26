import 'dart:convert';
import 'dart:io';

import 'package:elimor/app.dart';
import 'package:elimor/companion/state.dart';
import 'package:elimor/data/sports.dart';
import 'package:elimor/data/stremio.dart';
import 'package:elimor/data/tmdb.dart';
import 'package:elimor/data/weather.dart';
import 'package:elimor/data/youtube.dart';
import 'package:elimor/data/youtube_tv.dart';
import 'package:elimor/host.dart';
import 'package:elimor/i18n.dart';
import 'package:elimor/providers.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/sources.dart';
import 'package:elimor/ui/home_screen.dart';
import 'package:elimor/ui/settings_kit.dart';
import 'package:elimor/ui/settings_screen.dart';
import 'package:elimor/ui/setup_wizard.dart';
import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _videos = 'com.example.videos';
const _other = 'com.example.other';

/// A Fire TV's screen, offline, with two apps of which [_videos] opens
/// YouTube's links; [prefs] as stored.
Future<(Settings, Sources)> _setUp(
  WidgetTester tester,
  Map<String, Object> prefs,
) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  addTearDown(() => I18n.language = 'en');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('app.elimor/host'),
        (call) async => switch (call.method) {
          'listApps' => [
            for (final p in [_videos, _other]) {'package': p, 'label': p},
          ],
          'appsFor' => [
            if ((call.arguments as Map)['uri'] == kYoutubeProbe) _videos,
          ],
          _ => null,
        },
      );
  SharedPreferences.setMockInitialValues(prefs);
  final s = await Settings.load();
  final store = MemStore();
  final sources = Sources(
    weather: WeatherSource(s, store, fetch: fake({}).call),
    tmdb: TmdbSource(s, store, fetch: fake({}).call, post: fakePost({}).call),
    stremio: StremioSource(
      s,
      store,
      client: StremioClient(post: fakePost({}).call),
    ),
    youtube: YoutubeSource(
      s,
      store,
      YoutubeTvClient(
        store: store,
        post: fakePost({}).call,
        getText: (_, {headers = const {}}) =>
            Future.error(const SocketException('offline')),
      ),
    ),
    sports: SportsSource(s, store, fetch: fake({}).call),
  );
  return (s, sources);
}

Future<Settings> _app(WidgetTester tester, Map<String, Object> prefs) async {
  final (s, sources) = await _setUp(tester, prefs);
  await tester.pumpWidget(ElimorApp(s, sources, MemStore()));
  await tester.pumpAndSettle();
  return s;
}

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsRow));

Future<void> _press(WidgetTester tester, String title) async {
  await tester.tap(_row(title));
  await tester.pumpAndSettle();
}

Future<void> _back(WidgetTester tester) async {
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
}

/// Continue until the last step, whose button says Done.
Future<void> _toDone(WidgetTester tester) async {
  for (var i = 0; i < 12 && find.text('Done').evaluate().isEmpty; i++) {
    await _press(tester, 'Continue');
  }
  expect(find.text('Done'), findsOneWidget);
}

void main() {
  group('firstDock', () {
    Future<Settings> settings() async {
      SharedPreferences.setMockInitialValues({});
      return Settings.load();
    }

    test('YouTube, the Stremio app once, then the Apps grid', () async {
      final s = await settings()
        ..youtubeProvider = _videos
        ..movieProvider = kStremioPackage
        ..seriesProvider = kStremioPackage
        ..serviceApps = {'8': 'com.example.flix'};
      expect(
        [for (final t in firstDock(s)) (t.package, t.icon)],
        [
          (_videos, 'youtube'),
          (kStremioPackage, 'app'),
          ('elimor:apps', 'apps'),
        ],
      );
    });

    test('streaming apps: the mapped ones, five tiles at most', () async {
      final s = await settings()
        ..serviceApps = {
          '1': 'a.one',
          '2': '',
          '3': 'a.two',
          '4': 'a.one',
          '5': 'a.three',
          '6': 'a.four',
        };
      expect(
        [for (final t in firstDock(s)) t.package],
        ['a.one', 'a.two', 'a.three', 'a.four', 'elimor:apps'],
      );
    });

    test('nothing chosen: the Apps grid alone', () async {
      expect(
        [for (final t in firstDock(await settings())) t.package],
        ['elimor:apps'],
      );
    });
  });

  testWidgets('a fresh install opens the setup, not the home', (tester) async {
    await _app(tester, {});
    expect(find.byType(SetupWizard), findsOneWidget);
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('Elimor'), findsOneWidget);
    expect(find.text('1 of 8'), findsOneWidget);
    // Back on the first step of a first run stays.
    await _back(tester);
    expect(find.byType(SetupWizard), findsOneWidget);
    // Home, with Launcher mode already on: nothing to go back to yet.
    Host.onInputsChanged = null;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          'app.elimor/host',
          const StandardMethodCodec().encodeMethodCall(
            const MethodCall('goHome'),
          ),
          null,
        );
    await tester.pumpAndSettle();
    expect(find.text('1 of 8'), findsOneWidget);
  });

  testWidgets('an install with settings goes straight home', (tester) async {
    final s = await _app(tester, {'tiles': '[]'});
    expect(s.setupDone, isTrue);
    expect(find.byType(SetupWizard), findsNothing);
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('the D-pad: focus on the step, Left to Continue, OK advances; '
      'Back goes one step back', (tester) async {
    await _app(tester, {});
    bool focused(String title) => Focus.of(
      tester.element(
        find.descendant(of: _row(title), matching: find.byType(Row)).first,
      ),
    ).hasPrimaryFocus;
    expect(focused('English'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(focused('Continue'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Where you are'), findsOneWidget);
    expect(find.text('2 of 8'), findsOneWidget);
    expect(_row('Skip'), findsOneWidget);
    // The first row of the step is the one OK opens the city search on.
    expect(focused('City'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsOneWidget);
    await _back(tester);
    expect(find.text('1 of 8'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('the language changes the setup at once', (tester) async {
    final s = await _app(tester, {});
    await _press(tester, 'Português');
    expect(s.language, 'pt');
    expect(find.text('Continuar'), findsOneWidget);
  });

  testWidgets('movies and series without a TMDB key say what they need', (
    tester,
  ) async {
    await _app(tester, {});
    for (var i = 0; i < 3; i++) {
      await _press(tester, 'Continue');
    }
    expect(find.text('Where titles open'), findsOneWidget);
    expect(_row('Movies'), findsOneWidget);
    expect(_row('YouTube'), findsNothing);
    expect(find.text(t('wizNeedsKey')), findsOneWidget);
  });

  testWidgets('how to get a TMDB key opens and closes under its row', (
    tester,
  ) async {
    await _app(tester, {});
    for (var i = 0; i < 2; i++) {
      await _press(tester, 'Continue');
    }
    expect(find.text(t('tmdbStep1')), findsNothing);
    await _press(tester, 'How to get a key');
    for (final k in ['tmdbStep1', 'tmdbStep2', 'tmdbStep3', 'tmdbStep4']) {
      expect(find.text(t(k)), findsOneWidget);
    }
    expect(find.byType(Image), findsNWidgets(5));
    // OK on the focused row, which stays on screen while the steps scroll in.
    Focus.of(
      tester.element(
        find
            .descendant(
              of: _row('How to get a key'),
              matching: find.byType(Row),
            )
            .first,
      ),
    ).requestFocus();
    await tester.pumpAndSettle();
    // Down walks into the steps, which scroll into view one by one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.text(t('tmdbStep1')))).hasPrimaryFocus,
      isTrue,
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text(t('tmdbStep1')), findsNothing);
  });

  testWidgets('a TMDB key typed but not saved is kept by Continue', (
    tester,
  ) async {
    final s = await _app(tester, {});
    for (var i = 0; i < 2; i++) {
      await _press(tester, 'Continue');
    }
    await _press(tester, 'TMDB key');
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    await tester.enterText(find.byType(TextField), ' typed-key ');
    await _press(tester, 'Continue');
    expect(s.tmdbKey, 'typed-key');
    expect(find.text('Where titles open'), findsOneWidget);
  });

  testWidgets('signing out of Stremio on its step keeps the place', (
    tester,
  ) async {
    final s = await _app(tester, {'stremioAuthKey': 'AUTH'});
    for (var i = 0; i < 5; i++) {
      await _press(tester, 'Continue');
    }
    expect(find.text('6 of 9'), findsOneWidget);
    s.stremioAuthKey = '';
    await s.save();
    await tester.pumpAndSettle();
    expect(find.text('6 of 9'), findsOneWidget);
    await _press(tester, 'Continue');
    expect(find.text('Sports'), findsWidgets);
    expect(find.text('6 of 8'), findsOneWidget);
  });

  testWidgets('Done keeps the setup done, seeds the dock and opens the home', (
    tester,
  ) async {
    final s = await _app(tester, {});
    await _toDone(tester);
    // No Stremio app: no Stremio step.
    expect(find.text('8 of 8'), findsOneWidget);
    expect(find.text(t('wizDoneHelp')), findsOneWidget);
    expect(_row('Skip'), findsNothing);
    await _press(tester, 'Done');
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(SetupWizard), findsNothing);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('setupDone'), isTrue);
    expect(s.youtubeProvider, _videos);
    expect(jsonDecode(prefs.getString('tiles')!), [
      const AppTile(_videos, 'youtube').toJson(),
      const AppTile('elimor:apps', 'apps').toJson(),
    ]);
  });

  testWidgets('the wizard publishes its step', (tester) async {
    await _app(tester, {});
    expect(companionState.step, SetupStep.welcome);
    await _press(tester, 'Continue');
    expect(companionState.step, SetupStep.location);
    await _toDone(tester);
    expect(companionState.step, SetupStep.done);
    await _press(tester, 'Done');
    expect(companionState.step, isNull);
  });

  testWidgets('a re-run from Settings leaves with Back and keeps the dock', (
    tester,
  ) async {
    final tiles = [const AppTile(_other, 'app').toJson()];
    final (s, sources) = await _setUp(tester, {
      'setupDone': true,
      'tiles': jsonEncode(tiles),
    });
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(s, sources)));
    await tester.pumpAndSettle();
    await _press(tester, 'About');
    await _press(tester, 'Run setup again');
    expect(find.byType(SetupWizard), findsOneWidget);
    await _back(tester);
    expect(find.byType(SetupWizard), findsNothing);
    expect(_row('Run setup again'), findsOneWidget);

    await _press(tester, 'Run setup again');
    await _toDone(tester);
    expect(find.text(t('wizDoneAgainHelp')), findsOneWidget);
    await _press(tester, 'Done');
    expect(find.byType(SetupWizard), findsNothing);
    expect(find.text('Settings'), findsOneWidget);
    expect(jsonEncode(s.tiles), jsonEncode(tiles));
    // A re-run does not choose for the user.
    expect(s.youtubeProvider, '');
  });
}
