import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/home_page.dart';
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

void main() {
  final calls = <String>[];
  late Tvs tvs;

  setUp(() async {
    I18n.language = 'en';
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tv.ilona.companion/host'),
          (c) async {
            calls.add(c.method);
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
}

String t0(String k) => t(k);
