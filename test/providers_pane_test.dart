import 'dart:async';
import 'dart:io';

import 'package:elimor/host.dart';
import 'package:elimor/providers.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/ui/settings_kit.dart';
import 'package:elimor/ui/settings_panes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

const _apps = {
  kStremioPackage: InstalledApp(kStremioPackage, 'Stremio', tv: true),
  'com.example.fork': InstalledApp('com.example.fork', 'Fork', tv: true),
  'com.example.tube': InstalledApp('com.example.tube', 'Tube', tv: true),
  'com.example.flix': InstalledApp('com.example.flix', 'Netflix', tv: true),
  'com.example.prime': InstalledApp(
    'com.example.prime',
    'Prime Video',
    tv: true,
  ),
};

String? _value(WidgetTester tester, String title) => tester
    .widget<SettingsRow>(
      find
          .ancestor(of: find.text(title), matching: find.byType(SettingsRow))
          .first,
    )
    .value;

Finder _choice(String label) =>
    find.descendant(of: find.byType(Dialog), matching: find.text(label));

Future<void> _tap(WidgetTester tester, Finder f) async {
  await tester.tap(f);
  await tester.pumpAndSettle();
}

Future<Settings> _open(
  WidgetTester tester,
  Widget Function(Settings) pane, {
  String tmdbKey = 'KEY',
  Map<String, String> serviceApps = const {},
}) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final s = (await Settings.load())
    ..tmdbKey = tmdbKey
    ..country = 'US'
    ..serviceApps = {...serviceApps};
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('app.elimor/host'), (
        call,
      ) async {
        if (call.method != 'appsFor') return null;
        return (call.arguments as Map)['uri'] == kStremioProbe
            ? [kStremioPackage, 'com.example.fork']
            : ['com.example.tube'];
      });
  await tester.pumpWidget(
    MaterialApp(
      home: ListenableBuilder(
        listenable: s,
        builder: (_, _) => SettingsPage(
          title: 'Open with',
          icon: Icons.open_in_new,
          child: pane(s),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return s;
}

void main() {
  final lists = {'graphql': 'jw_packages.json'};

  testWidgets('movies and series: a Stremio app or my streaming apps; the '
      'services page and the first-stream switch show when they apply', (
    tester,
  ) async {
    final s = await _open(tester, (s) => ProvidersPane(s, _apps));
    expect(_value(tester, 'Movies'), 'My streaming apps');
    expect(_value(tester, 'YouTube'), 'Any app');
    expect(_value(tester, 'Streaming services'), '0');
    expect(find.text('Play the first stream'), findsNothing);

    await _tap(tester, find.text('Movies'));
    expect(_choice('My streaming apps'), findsOneWidget);
    expect(_choice('Stremio'), findsOneWidget);
    expect(_choice('Fork'), findsOneWidget);
    expect(_choice('Netflix'), findsNothing);
    await _tap(tester, _choice('Stremio'));
    expect(s.movieProvider, kStremioPackage);
    expect(find.text('Play the first stream'), findsOneWidget);
    expect(find.text('Streaming services'), findsOneWidget);

    await _tap(tester, find.text('Series'));
    await _tap(tester, _choice('Fork'));
    expect(s.seriesProvider, 'com.example.fork');
    expect(find.text('Streaming services'), findsNothing);

    await _tap(tester, find.text('Movies'));
    await _tap(tester, _choice('My streaming apps'));
    expect(s.movieProvider, '');
    expect(find.text('Play the first stream'), findsNothing);
    expect(find.text('Streaming services'), findsOneWidget);
  });

  testWidgets('YouTube: the apps that open its links, or any other app', (
    tester,
  ) async {
    final s = await _open(tester, (s) => ProvidersPane(s, _apps));
    await _tap(tester, find.text('YouTube'));
    expect(_choice('Tube'), findsOneWidget);
    expect(_choice('Netflix'), findsNothing);
    await _tap(tester, _choice('Tube'));
    expect(s.youtubeProvider, 'com.example.tube');
    expect(_value(tester, 'YouTube'), 'Tube');

    await _tap(tester, find.text('YouTube'));
    await _tap(tester, _choice('Other app…'));
    expect(_choice('Netflix'), findsOneWidget);
    await _tap(tester, _choice('Fork'));
    expect(s.youtubeProvider, 'com.example.fork');
  });

  testWidgets('streaming services: the country\'s, each with its app or a '
      'suggestion that OK confirms; None is kept', (tester) async {
    final net = fakePost(lists);
    final s = await _open(
      tester,
      (s) => ServicesPane(s, _apps, post: net.call),
      serviceApps: {'350': 'com.example.gone'},
    );
    expect(net.calls.single.$2['variables'], {'country': 'US'});
    expect(_value(tester, 'Netflix'), 'Netflix?');
    expect(_value(tester, 'Amazon Prime Video'), 'Prime Video?');
    expect(_value(tester, 'Disney Plus'), 'None');
    expect(_value(tester, 'Apple TV'), 'Not installed');
    expect(find.text('Netflix Kids'), findsNothing, reason: 'no subscription');

    // The suggestion has the focus: OK takes it.
    await _tap(tester, find.text('Netflix').first);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(s.serviceApps['8'], 'com.example.flix');
    expect(_value(tester, 'Netflix'), 'Netflix');

    await _tap(tester, find.text('Amazon Prime Video'));
    await _tap(tester, _choice('None'));
    expect(s.serviceApps['119'], '');
    expect(_value(tester, 'Amazon Prime Video'), 'None');
  });

  testWidgets('streaming services: without a TMDB key nothing is asked; a '
      'failure can be tried again', (tester) async {
    final none = fakePost(lists);
    await _open(
      tester,
      (s) => ServicesPane(s, _apps, post: none.call),
      tmdbKey: '',
    );
    expect(none.calls, isEmpty);
    expect(find.textContaining('TMDB key'), findsOneWidget);

    var fail = true;
    final net = fakePost(lists);
    final answer = Completer<void>();
    Future<Map<String, dynamic>> flaky(
      Uri uri,
      Map<String, dynamic> body, {
      Map<String, String> headers = const {},
    }) async {
      if (fail) throw const SocketException('offline');
      await answer.future;
      return net.call(uri, body, headers: headers);
    }

    await tester.pumpWidget(const SizedBox());
    await _open(tester, (s) => ServicesPane(s, _apps, post: flaky));
    expect(find.text('Network error'), findsOneWidget);
    fail = false;
    await _tap(tester, find.text('Check again'));
    answer.complete();
    await tester.pumpAndSettle();
    expect(find.text('Disney Plus'), findsOneWidget);
    // The list that came late has a focused row, as the page had.
    expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
  });
}
