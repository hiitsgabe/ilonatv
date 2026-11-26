import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/releases.dart';
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
    await t.tap(find.text(t0('pairWithCode')));
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
      expect(find.text(tvBanner), findsOneWidget);
      await t.tap(find.text(t0('instUpdate')));
      await t.pumpAndSettle();
      expect(find.byType(InstallFlow), findsOneWidget);
    },
  );

  for (final v in ['0.7.0', '0.8.0', '']) {
    testWidgets('a TV at "$v" shows no banner', (t) async {
      await withUpdates(t, check('0.7.0'), clientFor: (_) => Versioned(v));
      await t.tap(find.text('Living'));
      await t.pumpAndSettle();
      expect(find.text(tvBanner), findsNothing);
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
      expect(find.text(tvBanner), findsOneWidget);
      await t.tap(find.byTooltip('Back'));
      await t.pumpAndSettle();
    }
    expect(fetches, 1);
  });
}

UpdateCheck check(String own, {String latest = 'v0.7.0'}) =>
    UpdateCheck(fetch: () async => latest, own: () async => own);

String t0(String k) => t(k);
