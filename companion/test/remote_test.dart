import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Fake extends TvClient {
  Fake() : super('1.2.3.4');
  final keys = <RemoteKey>[];
  TvResult<void> keyResult = const Ok(null);
  TvResult<TvInfo> infoResult = const Unpaired();
  final events$ = StreamController<TvInfo>();
  (String, bool)? tmdb;
  Place? city;

  @override
  Future<TvResult<void>> key(RemoteKey k) async {
    keys.add(k);
    return keyResult;
  }

  @override
  Future<TvResult<TvInfo>> info() async => infoResult;

  @override
  Stream<TvInfo> events() => events$.stream;

  @override
  Future<TvResult<String>> setupTmdb(String key, {bool save = true}) async {
    tmdb = (key, save);
    return const Ok('keyOk');
  }

  @override
  Future<TvResult<List<Place>>> cities(String q) async => const Ok([
    Place(name: 'Lisbon', region: 'Lisboa', country: 'Portugal', countryCode: 'PT', lat: 1, lon: 2),
  ]);

  @override
  Future<TvResult<void>> setCity(Place p) async {
    city = p;
    return const Ok(null);
  }
}

TvInfo info(String? step) =>
    TvInfo(protocol: 1, version: '1', step: step, inFront: true, launcherMode: false);

void main() {
  late Fake client;
  late Tvs tvs;
  final tv = Tv(host: '1.2.3.4', port: 8642, name: 'IlonaTv on Box', token: 'x');

  Future<void> open(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    client = Fake();
    tvs = Tvs();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute(builder: (_) => RemotePage(tv: tv, client: client, tvs: tvs)),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
  }

  testWidgets('edge taps send arrows, centre sends ok', (t) async {
    await open(t);
    final c = t.getCenter(find.byKey(const Key('pad')));
    final r = t.getSize(find.byKey(const Key('pad'))).width / 2;
    await t.tapAt(c + Offset(r * 0.8, 0));
    await t.tapAt(c);
    await t.tapAt(c + Offset(0, -r * 0.8));
    expect(client.keys, [RemoteKey.right, RemoteKey.ok, RemoteKey.up]);
  });

  testWidgets('swipe moves', (t) async {
    await open(t);
    await t.drag(find.byKey(const Key('pad')), const Offset(-60, 0));
    expect(client.keys, [RemoteKey.left]);
  });

  testWidgets('409 shows the banner and the launcher tip', (t) async {
    await open(t);
    client.keyResult = const NotInFront(launcherMode: false);
    await t.tap(find.byKey(const Key('key-home')));
    await t.pumpAndSettle();
    expect(find.text(t0('notInFront')), findsOneWidget);
    expect(find.text(t0('launcherTip')), findsOneWidget);
  });

  testWidgets('unpaired forgets and goes home', (t) async {
    await open(t);
    await tvs.savePaired(tv, 'x');
    client.keyResult = const Unpaired();
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
    expect(find.text(t0('removedPairAgain')), findsOneWidget);
    expect(tvs.all.where((e) => e.token != null), isEmpty);
  });

  testWidgets('unreachable shows Retry', (t) async {
    await open(t);
    client.keyResult = const Unreachable('x');
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(find.text("Can't reach IlonaTv"), findsOneWidget);
    expect(find.text(t0('retry')), findsOneWidget);
  });

  testWidgets('a stream that ends and an unpaired info forgets', (t) async {
    await open(t);
    await client.events$.close();
    await t.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('step tmdb shows the key card; Save saves', (t) async {
    await open(t);
    client.events$.add(info('tmdb'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'abc');
    await t.tap(find.text(t0('save')));
    await t.pumpAndSettle();
    expect(client.tmdb, ('abc', true));
    expect(find.text(t0('keyOk')), findsOneWidget);
  });

  testWidgets('step location shows city search; tap sets city', (t) async {
    await open(t);
    client.events$.add(info('location'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'lis');
    await t.tap(find.byIcon(Icons.search));
    await t.pumpAndSettle();
    await t.tap(find.text('Lisbon'));
    await t.pumpAndSettle();
    expect(client.city?.name, 'Lisbon');
  });
}

String t0(String k) => t(k);
