import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_protocol/releases.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/home_page.dart';
import 'package:ilonatv_companion/ui/install/install_flow.dart';
import 'package:ilonatv_companion/ui/pair_page.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Quiet extends TvClient {
  Quiet() : super('10.0.0.5');

  @override
  Stream<TvInfo> events() => StreamController<TvInfo>().stream;

  @override
  Future<TvResult<List<TvRow>>> rows() async => const Ok([]);
}

class Versioned extends TvClient {
  Versioned(this.version) : super('10.0.0.5');
  final String version;

  @override
  Stream<TvInfo> events() =>
      (StreamController<TvInfo>()..add(
            TvInfo(
              protocol: 1,
              version: version,
              inFront: true,
              launcherMode: false,
            ),
          ))
          .stream;

  @override
  Future<TvResult<List<TvRow>>> rows() async => const Ok([]);
}

Future<void> native(String method, Map<String, Object?> args) async {
  const channel = MethodChannel('tv.ilona.companion/host');
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(MethodCall(method, args)),
        (_) {},
      );
}

Future<void> found(String host, String name) =>
    native('found', {'name': name, 'host': host, 'port': 8642});

void main() {
  final calls = <String>[];
  final args = <Object?>[];
  late Tvs tvs;

  setUp(() async {
    I18n.language = 'en';
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    args.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tv.ilona.companion/host'),
          (c) async {
            // The remote's hold on the volume rocker, not discovery.
            if (c.method == 'volumeKeys') return null;
            calls.add(c.method);
            args.add(c.arguments);
            return null;
          },
        );
    tvs = Tvs();
    await tvs.savePaired(
      Tv(host: '10.0.0.5', port: 8642, name: 'Living'),
      'tok',
    );
  });

  Future<void> home(WidgetTester t) async {
    await t.pumpWidget(
      MaterialApp(
        home: HomePage(tvs: tvs, clientFor: (_) => Quiet()),
      ),
    );
    expect(calls, ['discoverStart']);
    calls.clear();
  }

  testWidgets('discovery stops under the remote and starts again after', (
    t,
  ) async {
    await home(t);
    await t.tap(find.text('Living'));
    await t.pumpAndSettle();
    expect(find.byType(RemotePage), findsOneWidget);
    expect(calls, ['discoverStop']);
    await t.tap(find.byTooltip('Back'));
    await t.pumpAndSettle();
    expect(calls, ['discoverStop', 'discoverStart']);
  });

  testWidgets('discovery stays on for pairing', (t) async {
    await home(t);
    await t.tap(find.text(t0('addTv')));
    await t.pumpAndSettle();
    expect(find.byType(PairPage), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('discovery stops while the app is hidden', (t) async {
    await home(t);
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    expect(calls, ['discoverStop']);
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    expect(calls, ['discoverStop', 'discoverStart']);
  });

  testWidgets('hiding the app under the remote does not start discovery', (
    t,
  ) async {
    await home(t);
    await t.tap(find.text('Living'));
    await t.pumpAndSettle();
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    expect(calls, ['discoverStop']);
  });

  testWidgets('paired TVs come first with their status, found ones after', (
    t,
  ) async {
    await home(t);
    expect(find.text(t0('yourTvs')), findsOneWidget);
    expect(find.text(t0('offline')), findsOneWidget);
    expect(find.text(t0('foundHere')), findsNothing);
    await found('10.0.0.9', 'Ilona TV on Office');
    await found('10.0.0.5', 'Ilona TV on Living');
    await t.pump();
    expect(find.text(t0('online')), findsOneWidget);
    expect(find.text(t0('foundHere')), findsOneWidget);
    expect(find.text('Ilona TV'), findsOneWidget);
    expect(find.text(t0('pairNow')), findsOneWidget);
    expect(find.text('10.0.0.5'), findsNothing, reason: 'no raw IPs');
    expect(find.text(t0('installOnTv')), findsOneWidget);
  });

  testWidgets('the one paired TV online opens the remote, once per launch', (
    t,
  ) async {
    await home(t);
    await found('10.0.0.5', 'Ilona TV on Living');
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.byType(RemotePage), findsOneWidget);
    await t.tap(find.byTooltip('Back'));
    await t.pumpAndSettle();
    await found('10.0.0.5', 'Ilona TV on Living');
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.byType(RemotePage), findsNothing);
  });

  testWidgets('two paired TVs online open nothing by themselves', (t) async {
    await tvs.savePaired(
      Tv(host: '10.0.0.6', port: 8642, name: 'Bedroom'),
      'tok',
    );
    await home(t);
    await found('10.0.0.5', 'Ilona TV on Living');
    await found('10.0.0.6', 'Ilona TV on Bedroom');
    await t.pump(const Duration(seconds: 1));
    await t.pumpAndSettle();
    expect(find.byType(RemotePage), findsNothing);
  });

  testWidgets('with no TV, Home says it is looking and offers QR, code and '
      'install', (t) async {
    await tvs.forget('10.0.0.5');
    await home(t);
    expect(find.text(t0('searchingTvs')), findsOneWidget);
    expect(find.text(t0('searchingHint')), findsOneWidget);
    expect(find.text(t0('scanQr')), findsOneWidget);
    expect(find.text(t0('installOnTv')), findsOneWidget);
    await t.tap(find.text(t0('typeCode')));
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(find.byType(PairPage), findsOneWidget);
  });

  Future<void> withUpdates(
    WidgetTester t,
    UpdateCheck u, {
    ClientFor? clientFor,
  }) async {
    await t.pumpWidget(
      MaterialApp(
        home: HomePage(
          tvs: tvs,
          clientFor: clientFor ?? (_) => Quiet(),
          updates: u,
        ),
      ),
    );
    await t.pumpAndSettle();
  }

  const appBanner = 'A new Ilona TV Companion is available (v0.7.0)';

  testWidgets('an older companion shows the banner, which opens the release', (
    t,
  ) async {
    await withUpdates(t, check('0.6.1'));
    expect(find.text(appBanner), findsOneWidget);
    calls.clear();
    args.clear();
    await t.tap(find.text(t0('getIt')));
    expect(calls, ['openUrl']);
    expect(args, ['https://github.com/hiitsgabe/ilonatv/releases/latest']);
  });

  testWidgets('the companion banner can be dismissed', (t) async {
    await withUpdates(t, check('0.6.1'));
    await t.tap(find.byTooltip(t0('close')));
    await t.pump();
    expect(find.text(appBanner), findsNothing);
  });

  for (final own in ['0.7.0', '0.7.1', 'dev']) {
    testWidgets('a companion at $own shows no banner', (t) async {
      await withUpdates(t, check(own));
      expect(find.textContaining('is available'), findsNothing);
    });
  }

  testWidgets('a failed check shows no banner', (t) async {
    await withUpdates(
      t,
      UpdateCheck(fetch: () async => null, own: () async => '0.6.1'),
    );
    expect(find.textContaining('is available'), findsNothing);
  });

  const tvBanner = 'Ilona TV v0.7.0 is available for this TV';

  testWidgets(
    'an older TV shows the banner, whose Update opens the installer',
    (t) async {
      await withUpdates(
        t,
        check('0.7.0'),
        clientFor: (_) => Versioned('0.6.1'),
      );
      await t.tap(find.text('Living'));
      await t.pumpAndSettle();
      expect(find.byTooltip(tvBanner), findsOneWidget);
      await t.tap(find.byKey(const Key('tvUpdate')));
      await t.pumpAndSettle();
      expect(find.byType(InstallFlow), findsOneWidget);
    },
  );

  for (final v in ['0.7.0', '0.8.0', '']) {
    testWidgets('a TV at "$v" shows no banner', (t) async {
      await withUpdates(t, check('0.7.0'), clientFor: (_) => Versioned(v));
      await t.tap(find.text('Living'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tvUpdate')), findsNothing);
      expect(find.textContaining('is available'), findsNothing);
    });
  }

  testWidgets('GitHub is asked once per launch, not per screen', (t) async {
    var fetches = 0;
    final u = UpdateCheck(
      fetch: () async {
        fetches++;
        return 'v0.7.0';
      },
      own: () async => '0.6.1',
    );
    await withUpdates(t, u, clientFor: (_) => Versioned('0.6.1'));
    for (var i = 0; i < 2; i++) {
      await t.tap(find.text('Living'));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('tvUpdate')), findsOneWidget);
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
    }
    expect(fetches, 1);
  });
}

UpdateCheck check(String own, {String latest = 'v0.7.0'}) =>
    UpdateCheck(fetch: () async => latest, own: () async => own);

String t0(String k) => t(k);
