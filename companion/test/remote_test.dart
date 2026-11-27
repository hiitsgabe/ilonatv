import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
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
  Completer<void>? gate;
  int infoCalls = 0;
  TvResult<TvInfo> infoResult = const Unpaired();
  final events$ = StreamController<TvInfo>();
  (String, bool)? tmdb;
  Place? city;

  @override
  Future<TvResult<void>> key(RemoteKey k) async {
    keys.add(k);
    if (gate != null) await gate!.future;
    return keyResult;
  }

  @override
  Future<TvResult<TvInfo>> info() async {
    infoCalls++;
    return infoResult;
  }

  bool endNow = false;
  @override
  Stream<TvInfo> events() => endNow ? const Stream.empty() : events$.stream;

  @override
  Future<TvResult<String>> setupTmdb(String key, {bool save = true}) async {
    tmdb = (key, save);
    return const Ok('keyOk');
  }

  Completer<void>? cityGate;
  List<Place>? cityResult;

  @override
  Future<TvResult<List<Place>>> cities(String q) async {
    if (cityGate != null) await cityGate!.future;
    return Ok(cityResult ?? _lisbon);
  }

  @override
  Future<TvResult<void>> setCity(Place p) async {
    city = p;
    return const Ok(null);
  }
}

class FakeAdb extends Adb {
  bool known = false;
  final connects = <AdbResult>[];
  final hosts = <String>[];
  final keys = <RemoteKey>[];
  bool keyOk = true;
  int closes = 0;

  @override
  Future<bool> knows(String host) async => known;

  @override
  Future<AdbResult> connect(String host, int port) async {
    hosts.add('$host:$port');
    return connects.isEmpty ? AdbResult.ok : connects.removeAt(0);
  }

  @override
  Future<bool> key(RemoteKey k) async {
    keys.add(k);
    return keyOk;
  }

  @override
  Future<void> close() async => closes++;
}

TvInfo outside(String? keysOutside) => TvInfo(
  protocol: 1,
  version: '1',
  inFront: false,
  launcherMode: true,
  keysOutside: keysOutside,
);

const _lisbon = [
  Place(
    name: 'Lisbon',
    region: 'Lisboa',
    country: 'Portugal',
    countryCode: 'PT',
    lat: 1,
    lon: 2,
  ),
];

TvInfo info(String? step) => TvInfo(
  protocol: 1,
  version: '1',
  step: step,
  inFront: true,
  launcherMode: false,
);

void main() {
  late Fake client;
  late FakeAdb adb;
  late Tvs tvs;
  final tv = Tv(
    host: '1.2.3.4',
    port: 8642,
    name: 'Ilona TV on Box',
    token: 'x',
  );

  Future<void> open(WidgetTester t) async {
    SharedPreferences.setMockInitialValues({});
    client = Fake();
    adb = FakeAdb();
    tvs = Tvs();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(c).push(
                MaterialPageRoute(
                  builder: (_) =>
                      RemotePage(tv: tv, client: client, tvs: tvs, adb: adb),
                ),
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

  testWidgets('volume and play/pause go to the TV', (t) async {
    await open(t);
    await t.tap(find.byKey(const Key('key-volumeDown')));
    await t.tap(find.byKey(const Key('key-playPause')));
    await t.tap(find.byKey(const Key('key-volumeUp')));
    await t.pumpAndSettle();
    expect(client.keys, [
      RemoteKey.volumeDown,
      RemoteKey.playPause,
      RemoteKey.volumeUp,
    ]);
    expect(adb.keys, isEmpty);
  });

  testWidgets('a TV that reaches every key outside gets them all', (t) async {
    await open(t);
    client.events$.add(outside('all'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-back')));
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.pumpAndSettle();
    expect(client.keys, [RemoteKey.back, RemoteKey.ok]);
    expect(adb.hosts, isEmpty);
  });

  testWidgets('another app in front on an older Android: a known TV connects '
      'over ADB, the D-pad goes there and Back to the TV', (t) async {
    await open(t);
    adb.known = true;
    client.events$.add(outside('backHome'));
    await t.pumpAndSettle();
    expect(adb.hosts, ['1.2.3.4:5555']);
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(adb.keys, [RemoteKey.ok]);
    expect(client.keys, [RemoteKey.back]);
    expect(find.text(t0('adbNote')), findsNothing);
    await t.tap(find.byType(BackButton));
    await t.pumpAndSettle();
    expect(adb.closes, 1);
  });

  testWidgets('without ADB the note says how to turn it on and offers to '
      'connect', (t) async {
    await open(t);
    client.events$.add(outside('backHome'));
    await t.pumpAndSettle();
    expect(adb.hosts, isEmpty, reason: 'never connects to an unknown TV alone');
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.pumpAndSettle();
    expect(client.keys, isEmpty);
    expect(find.text(t0('adbNote')), findsOneWidget);
    expect(find.text(t0('adbHow')), findsOneWidget);
    adb.connects.add(AdbResult.unauthorized);
    await t.tap(find.text(t0('adbConnect')));
    await t.pumpAndSettle();
    expect(adb.hosts, ['1.2.3.4:5555']);
    expect(find.text(t0('adbDenied')), findsOneWidget);
    await t.tap(find.text(t0('adbConnect')));
    await t.pumpAndSettle();
    expect(find.text(t0('adbNote')), findsNothing);
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.pumpAndSettle();
    expect(adb.keys, [RemoteKey.ok]);
  });

  testWidgets('on an older Android with ADB up, volume and play/pause go '
      'over ADB, in front or not', (t) async {
    await open(t);
    adb.known = true;
    client.events$.add(outside('backHome'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-volumeUp')));
    await t.tap(find.byKey(const Key('key-mute')));
    await t.pumpAndSettle();
    client.events$.add(
      const TvInfo(
        protocol: 1,
        version: '1',
        inFront: true,
        launcherMode: true,
        keysOutside: 'backHome',
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-playPause')));
    await t.tapAt(
      t.getCenter(find.byKey(const Key('pad'))) - const Offset(0, 100),
    );
    await t.pumpAndSettle();
    expect(adb.keys, [RemoteKey.volumeUp, RemoteKey.mute, RemoteKey.playPause]);
    expect(client.keys, [RemoteKey.up]);
  });

  testWidgets('a 409 the phone sends over ADB shows no Open Ilona TV', (
    t,
  ) async {
    await open(t);
    client.events$.add(
      const TvInfo(
        protocol: 1,
        version: '1',
        inFront: true,
        launcherMode: true,
        keysOutside: 'backHome',
      ),
    );
    await t.pumpAndSettle();
    client.keyResult = const NotInFront(launcherMode: true);
    await t.tapAt(
      t.getCenter(find.byKey(const Key('pad'))) - const Offset(0, 100),
    );
    await t.pumpAndSettle();
    expect(find.text(t0('notInFront')), findsNothing);
    expect(find.text(t0('adbNote')), findsOneWidget);
  });

  testWidgets('an older TV with Ilona TV in front gets no ADB note', (t) async {
    await open(t);
    client.events$.add(info(null));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-volumeUp')));
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.pumpAndSettle();
    expect(client.keys, [RemoteKey.volumeUp, RemoteKey.ok]);
    expect(find.text(t0('adbNote')), findsNothing);
  });

  testWidgets('ADB closes while the phone app is away and reconnects on '
      'return', (t) async {
    await open(t);
    adb.known = true;
    client.events$.add(outside('backHome'));
    await t.pumpAndSettle();
    expect(adb.hosts, hasLength(1));
    for (final s in [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle();
    expect(adb.closes, 1);
    for (final s in [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]) {
      t.binding.handleAppLifecycleStateChanged(s);
    }
    await t.pumpAndSettle();
    expect(adb.hosts, hasLength(2));
    await t.tapAt(t.getCenter(find.byKey(const Key('pad'))));
    await t.pumpAndSettle();
    expect(adb.keys, [RemoteKey.ok]);
  });

  testWidgets('the note goes when Ilona TV is back in front', (t) async {
    await open(t);
    client.events$.add(outside('none'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('key-home')));
    await t.pumpAndSettle();
    expect(find.text(t0('adbNote')), findsOneWidget);
    client.events$.add(info(null));
    await t.pumpAndSettle();
    expect(find.text(t0('adbNote')), findsNothing);
  });

  testWidgets('a dropped ADB shell brings the note back', (t) async {
    await open(t);
    adb.known = true;
    client.events$.add(outside('none'));
    await t.pumpAndSettle();
    adb.keyOk = false;
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(find.text(t0('adbNote')), findsOneWidget);
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
    expect(find.text("Can't reach Ilona TV"), findsOneWidget);
    expect(find.text(t0('retry')), findsOneWidget);
  });

  testWidgets('a stream that ends and an unpaired info forgets', (t) async {
    await open(t);
    await client.events$.close();
    await t.pumpAndSettle();
    expect(find.text('go'), findsOneWidget);
  });

  testWidgets('rapid taps: one in flight, at most 3 queued, in order', (
    t,
  ) async {
    await open(t);
    client.gate = Completer();
    final c = t.getCenter(find.byKey(const Key('pad')));
    final r = t.getSize(find.byKey(const Key('pad'))).width / 2;
    for (final o in [
      Offset(r * .8, 0),
      Offset(-r * .8, 0),
      Offset(0, r * .8),
      Offset(0, -r * .8),
      Offset.zero,
    ]) {
      await t.tapAt(c + o);
    }
    expect(client.keys, [RemoteKey.right]);
    final g = client.gate!;
    client.gate = null;
    g.complete();
    await t.pumpAndSettle();
    expect(client.keys, [
      RemoteKey.right,
      RemoteKey.left,
      RemoteKey.down,
      RemoteKey.up,
    ]);
  });

  testWidgets('the tmdb key field is obscured', (t) async {
    await open(t);
    client.events$.add(info('tmdb'));
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField)).obscureText, isTrue);
  });

  testWidgets('three failed reconnects show Cant reach', (t) async {
    await open(t);
    client.infoResult = Ok(info(null));
    client.endNow = true;
    await client.events$.close();
    await t.pump();
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(seconds: 3));
    }
    expect(find.text("Can't reach Ilona TV"), findsOneWidget);
    expect(client.infoCalls, 3);
  });

  testWidgets('small screen with the card does not overflow', (t) async {
    t.view.physicalSize = const Size(360, 480);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    await open(t);
    client.events$.add(info('tmdb'));
    await t.pumpAndSettle();
  });

  testWidgets('with the card shown, a vertical swipe on the pad sends a key', (
    t,
  ) async {
    await open(t);
    client.events$.add(info('tmdb'));
    await t.pumpAndSettle();
    final before = t.getTopLeft(find.byType(TextField));
    await t.drag(find.byKey(const Key('pad')), const Offset(0, 80));
    await t.pumpAndSettle();
    expect(client.keys, contains(RemoteKey.down));
    expect(t.getTopLeft(find.byType(TextField)), before);
  });

  testWidgets('step tmdb shows the key card; Save saves', (t) async {
    await open(t);
    client.events$.add(info('tmdb'));
    await t.pumpAndSettle();
    await t.enterText(find.byType(TextField), 'abc');
    await t.tap(find.text(t0('save')));
    await t.pumpAndSettle();
    expect(client.tmdb, ('abc', true));
    expect(find.text(t0('keySaved')), findsOneWidget);
    await t.tap(find.text(t0('test')));
    await t.pumpAndSettle();
    expect(client.tmdb, ('abc', false));
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
    expect(find.text('Lisboa, Portugal'), findsNothing);
    expect(
      find.text(t0('citySet').replaceAll('{city}', 'Lisbon')),
      findsOneWidget,
    );
  });

  testWidgets('an Ok after Unreachable clears the banner', (t) async {
    await open(t);
    client.keyResult = const Unreachable('x');
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(find.text("Can't reach Ilona TV"), findsOneWidget);
    client.keyResult = const Ok(null);
    await t.tap(find.byKey(const Key('key-back')));
    await t.pumpAndSettle();
    expect(find.text("Can't reach Ilona TV"), findsNothing);
  });

  testWidgets('Back and Home are labelled in the language', (t) async {
    I18n.language = 'pt';
    addTearDown(() => I18n.language = 'en');
    await open(t);
    expect(find.bySemanticsLabel(t0('back')), findsOneWidget);
    expect(find.bySemanticsLabel(t0('home')), findsOneWidget);
    expect(t0('back'), isNot('Back'));
  });

  testWidgets('city search shows progress, then nothing found', (t) async {
    await open(t);
    client.events$.add(info('location'));
    await t.pumpAndSettle();
    client.cityGate = Completer();
    client.cityResult = const [];
    await t.enterText(find.byType(TextField), 'zzz');
    await t.tap(find.byIcon(Icons.search));
    await t.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    client.cityGate!.complete();
    await t.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text(t0('noResults')), findsOneWidget);
  });
}

String t0(String k) => t(k);
