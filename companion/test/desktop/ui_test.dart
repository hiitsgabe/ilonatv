import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/main.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/about_sheet.dart';
import 'package:ilonatv_companion/ui/home_page.dart';
import 'package:ilonatv_companion/ui/install/install_flow.dart';
import 'package:ilonatv_companion/ui/pair_page.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:ilonatv_companion/version.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:ilonatv_protocol/releases.dart';
import 'package:shared_preferences/shared_preferences.dart';

final desktop = TargetPlatformVariant({
  TargetPlatform.macOS,
  TargetPlatform.windows,
});

class NoDiscovery implements Discovery {
  @override
  void start(
    void Function(String, String, int) found,
    void Function(String) lost,
  ) {}

  @override
  void stop() {}
}

class DesktopFakeAdb extends Adb {
  DesktopFakeAdb({this.tools = false});
  bool tools;
  final log = <String>[];
  Object? downloadError;

  @override
  bool get ready => tools;

  @override
  Future<void> download({void Function(int got, int total)? progress}) async {
    log.add('download');
    progress?.call(5, 10);
    if (downloadError case final e?) {
      downloadError = null;
      throw e;
    }
    tools = true;
  }

  Completer<void>? pairGate;

  @override
  Future<bool> canPair() async => tools;

  @override
  Future<String?> pair(String host, int port, String code) async {
    log.add('pair $host:$port $code');
    await pairGate?.future;
    return null;
  }

  @override
  Future<AdbResult> connect(String host, int port) async {
    log.add('connect $host:$port');
    return AdbResult.unauthorized;
  }

  @override
  Future<void> close() async => log.add('close');
}

class Keys extends TvClient {
  Keys() : super('1.2.3.4');
  final keys = <RemoteKey>[];

  @override
  Future<TvResult<void>> key(RemoteKey k) async {
    keys.add(k);
    return const Ok(null);
  }

  @override
  Stream<TvInfo> events() => StreamController<TvInfo>().stream;
}

/// Another app in front on an older TV: the remote wants ADB for the keys.
class Outside extends Keys {
  @override
  Stream<TvInfo> events() =>
      (StreamController<TvInfo>()..add(
            const TvInfo(
              protocol: 1,
              version: '1',
              inFront: false,
              launcherMode: true,
            ),
          ))
          .stream;
}

class Newer extends ReleaseSource {
  final asked = <String>[];

  @override
  Future<ReleaseAsset?> named(String name) async {
    asked.add(name);
    return ReleaseAsset(
      url: Uri.parse('https://example.test/$name'),
      size: 1,
      version: 'v9.0.0',
      sha256: '0' * 64,
    );
  }
}

void main() {
  final channel = <String>[];

  setUp(() {
    I18n.language = 'en';
    SharedPreferences.setMockInitialValues({});
    channel.clear();
    for (final name in ['tv.ilona.companion/host', 'tv.ilona.companion/adb']) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(MethodChannel(name), (c) async {
            channel.add(c.method);
            return null;
          });
    }
  });

  testWidgets('Home offers the code, not the camera', (t) async {
    await t.pumpWidget(
      MaterialApp(
        home: HomePage(
          tvs: Tvs(discovery: NoDiscovery()),
          clientFor: (_) => throw UnimplementedError(),
        ),
      ),
    );
    expect(find.text(t0('scanQr')), findsNothing);
    expect(find.text(t0('typeCode')), findsOneWidget);
    await t.tap(find.text(t0('typeCode')));
    await t.pumpAndSettle();
    expect(find.byType(PairPage), findsOneWidget);
    expect(find.text(t0('scanQr')), findsNothing);
    expect(channel, isEmpty);
  }, variant: desktop);

  testWidgets('the window keeps the app phone-wide, centred', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await t.pumpWidget(CompanionApp(tvs: Tvs(discovery: NoDiscovery())));
    final home = t.getRect(find.byType(HomePage));
    expect(home.width, 480);
    expect(home.center.dx, 800);
  }, variant: desktop);

  testWidgets('About shows the built-in version; an update opens the page', (
    t,
  ) async {
    final releases = Newer();
    final opened = <String>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutSheet(
            releases: releases,
            open: (u) async {
              opened.add(u);
              return true;
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text(kVersion), findsOneWidget);
    await t.tap(find.text(t0('checkUpdates')));
    await t.pumpAndSettle();
    await t.tap(find.text(t0('updateTo').replaceAll('{version}', 'v9.0.0')));
    await t.pumpAndSettle();
    expect(opened, [releasePage]);
    expect(
      releases.asked.single,
      matches(r'^ilonatv-companion-(macos|windows)\.zip$'),
    );
    expect(channel, isEmpty);
  }, variant: desktop);

  testWidgets('arrows and Enter drive the remote; no vibration setting', (
    t,
  ) async {
    final client = Keys();
    final tvs = Tvs(discovery: NoDiscovery());
    await t.pumpWidget(
      MaterialApp(
        home: RemotePage(
          tv: Tv(host: '1.2.3.4', port: 8642, name: 'TV', token: 'x'),
          client: client,
          tvs: tvs,
          adb: DesktopFakeAdb(),
        ),
      ),
    );
    await t.pumpAndSettle();
    for (final k in [
      LogicalKeyboardKey.arrowUp,
      LogicalKeyboardKey.arrowRight,
      LogicalKeyboardKey.enter,
      LogicalKeyboardKey.escape,
    ]) {
      await t.sendKeyEvent(k);
      await t.pumpAndSettle();
    }
    expect(client.keys, [
      RemoteKey.up,
      RemoteKey.right,
      RemoteKey.ok,
      RemoteKey.back,
    ]);
    await t.tap(find.byKey(const Key('more')));
    await t.pumpAndSettle();
    expect(find.text(t0('vibration')), findsNothing);
  }, variant: desktop);

  testWidgets('a hidden window drops ADB, and showing it connects again', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({
      'adbHosts': ['1.2.3.4'],
    });
    final adb = DesktopFakeAdb(tools: true);
    await t.pumpWidget(
      MaterialApp(
        home: RemotePage(
          tv: Tv(host: '1.2.3.4', port: 8642, name: 'TV', token: 'x'),
          client: Outside(),
          tvs: Tvs(discovery: NoDiscovery()),
          adb: adb,
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(adb.log, ['connect 1.2.3.4:5555']);
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle();
    expect(adb.log.last, 'close');
    for (final s in [AppLifecycleState.inactive, AppLifecycleState.resumed]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle();
    expect(adb.log, ['connect 1.2.3.4:5555', 'close', 'connect 1.2.3.4:5555']);
  }, variant: desktop);

  testWidgets('closing the app closes ADB first, then lets it exit', (t) async {
    final adb = DesktopFakeAdb();
    final listener = closeAdbOnExit(adb);
    addTearDown(listener.dispose);
    expect(await t.binding.handleRequestAppExit(), AppExitResponse.exit);
    expect(adb.log, ['close']);
  }, variant: desktop);

  group('installer', () {
    Future<DesktopFakeAdb> open(WidgetTester t, {bool tools = false}) async {
      final adb = DesktopFakeAdb(tools: tools);
      await t.pumpWidget(
        MaterialApp(
          home: InstallFlow(
            adb: adb,
            tvs: Tvs(discovery: NoDiscovery()),
            clientFor: (_) => throw UnimplementedError(),
            scan: () => Stream.value('10.0.0.7'),
          ),
        ),
      );
      return adb;
    }

    Future<void> tap(WidgetTester t, String text) async {
      await t.tap(find.text(text));
      await t.pumpAndSettle();
    }

    testWidgets('asks before downloading adb, links the terms, then connects', (
      t,
    ) async {
      final adb = await open(t);
      await tap(t, t0('instFireTv'));
      await tap(t, t0('next'));
      await tap(t, '10.0.0.7');
      expect(find.text(t0('adbToolsTitle')), findsOneWidget);
      expect(find.text(t0('adbToolsTerms')), findsOneWidget);
      await tap(t, t0('cancel'));
      expect(adb.log, isEmpty);
      expect(find.text(t0('instFindTitle')), findsOneWidget);

      await tap(t, '10.0.0.7');
      adb.downloadError = const BadChecksum();
      await tap(t, t0('adbToolsDownload'));
      expect(find.text(t0('adbToolsBadChecksum')), findsOneWidget);
      await tap(t, t0('adbToolsDownload'));
      expect(adb.log, [
        'download',
        'download',
        'close',
        'connect 10.0.0.7:5555',
      ]);
    }, variant: desktop);

    testWidgets('Google TV pairs with the code, then connects', (t) async {
      final adb = await open(t, tools: true);
      await tap(t, t0('instGoogleTv'));
      expect(find.text(t0('instUseComputer')), findsNothing);
      await tap(t, t0('next'));
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.7:37005');
      await t.enterText(fields.at(1), '482913');
      await t.enterText(fields.at(2), '10.0.0.7:42131');
      await tap(t, t0('instPairConnect'));
      expect(adb.log, [
        'pair 10.0.0.7:37005 482913',
        'close',
        'connect 10.0.0.7:42131',
      ]);
    }, variant: desktop);

    testWidgets('Enter while pairing does not pair again', (t) async {
      final adb = await open(t, tools: true);
      adb.pairGate = Completer();
      await tap(t, t0('instGoogleTv'));
      await tap(t, t0('next'));
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.7:37005');
      await t.enterText(fields.at(1), '482913');
      await t.enterText(fields.at(2), '10.0.0.7:42131');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(adb.log, ['pair 10.0.0.7:37005 482913']);
      adb.pairGate!.complete();
      await t.pumpAndSettle();
      expect(adb.log.last, 'connect 10.0.0.7:42131');
    }, variant: desktop);

    testWidgets('a pairing address without its port is refused', (t) async {
      final adb = await open(t, tools: true);
      await tap(t, t0('instGoogleTv'));
      await tap(t, t0('next'));
      final fields = find.byType(TextField);
      await t.enterText(fields.at(0), '10.0.0.7');
      await t.enterText(fields.at(1), '482913');
      await t.enterText(fields.at(2), '10.0.0.7:42131');
      await tap(t, t0('instPairConnect'));
      expect(find.text(t0('badAddress')), findsOneWidget);
      expect(adb.log, isEmpty);
    }, variant: desktop);
  });
}

String t0(String k) => t(k);
