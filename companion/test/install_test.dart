import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/install/install_flow.dart';
import 'package:ilonatv_companion/ui/home_page.dart';
import 'package:ilonatv_companion/ui/install/scan.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _secret = '0123456789abcdef0123456789abcdef';

class FakeAdb extends Adb {
  FakeAdb({
    this.sdk = '30',
    this.abis = 'arm64-v8a,armeabi-v7a,armeabi',
    this.packages = '',
    this.hang,
  });
  final String sdk, abis, packages;
  String? hang;
  final log = <String>[];
  final connects = <AdbResult>[];
  String? installed;

  @override
  Future<AdbResult> connect(String host, int port) async {
    log.add('connect $host:$port');
    return connects.isEmpty ? AdbResult.ok : connects.removeAt(0);
  }

  @override
  Future<ShellResult> shell(String cmd) async {
    log.add(cmd);
    if (cmd == hang) return Completer<ShellResult>().future;
    final out = switch (cmd) {
      'getprop ro.build.version.sdk' => '$sdk\n',
      'getprop ro.product.cpu.abilist' => '$abis\n',
      'pm list packages tv.ilona.app' => packages,
      'content query --uri content://tv.ilona.app.pairing/secret' =>
        'Row: 0 secret=$_secret\n',
      _ => '',
    };
    return ShellResult(0, out);
  }

  @override
  Future<String?> install(String path) async {
    log.add('install ${path.split('/').last}');
    installed = path;
    return null;
  }

  @override
  Future<void> close() async => log.add('close');
}

class FakeClient extends TvClient {
  FakeClient() : super('10.0.0.7');
  String? secret, name;

  @override
  Future<TvResult<TvInfo>> info() async => const Unpaired();

  @override
  Future<TvResult<String>> pair({
    String? code,
    String? secret,
    required String name,
  }) async {
    this.secret = secret;
    this.name = name;
    return const Ok('tok');
  }

  @override
  Stream<TvInfo> events() => const Stream.empty();
}

class FakeAssets extends CachingAssetBundle {
  FakeAssets(this.files);
  final Set<String> files;

  @override
  Future<ByteData> load(String key) async {
    if (!files.contains(key)) throw FlutterError('Unable to load asset: $key');
    return ByteData.sublistView(Uint8List.fromList([1, 2, 3]));
  }
}

void main() {
  late Tvs tvs;
  late FakeClient client;

  setUp(() {
    I18n.language = 'en';
    SharedPreferences.setMockInitialValues({});
    tvs = Tvs();
    client = FakeClient();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tv.ilona.companion/host'),
          (call) async => call.method == 'deviceName' ? 'Pixel 9' : null,
        );
  });

  Future<void> pump(
    WidgetTester tester,
    FakeAdb adb, {
    Set<String> apks = const {
      'assets/tv/ilonatv-arm64-v8a.apk',
      'assets/tv/ilonatv-armeabi-v7a.apk',
    },
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: InstallFlow(
          adb: adb,
          tvs: tvs,
          assets: FakeAssets(apks),
          clientFor: (_) => client,
          scan: () => Stream.value('10.0.0.7'),
        ),
      ),
    );
  }

  Future<void> toConnect(WidgetTester tester) async {
    await tester.tap(find.text(t('instFireTv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0.0.7'));
    await tester.pumpAndSettle();
  }

  testWidgets('the happy path ends paired, commands in order', (tester) async {
    final adb = FakeAdb();
    await pump(tester, adb);
    expect(find.text(t('instStepOf').replaceAll('{n}', '1')), findsOneWidget);
    await toConnect(tester);
    expect(find.text(t('instInstall')), findsOneWidget);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();

    expect(find.text(t('instDone')), findsOneWidget);
    expect(adb.log, [
      'close',
      'connect 10.0.0.7:5555',
      'getprop ro.build.version.sdk',
      'getprop ro.product.cpu.abilist',
      'pm list packages tv.ilona.app',
      'install ilonatv-arm64-v8a.apk',
      'pm grant tv.ilona.app android.permission.WRITE_SECURE_SETTINGS',
      'pm grant tv.ilona.app android.permission.DUMP',
      'pm grant tv.ilona.app android.permission.PACKAGE_USAGE_STATS',
      'am start -n tv.ilona.app/.MainActivity',
      'content query --uri content://tv.ilona.app.pairing/secret',
    ]);
    expect(client.secret, _secret);
    expect(client.name, 'Pixel 9');
    expect(tvs.all.single.token, 'tok');

    await tester.tap(find.text(t('instOpenRemote')));
    await tester.pumpAndSettle();
    expect(adb.log.last, 'close');
    expect(find.byType(RemotePage), findsOneWidget);
  });

  testWidgets('unauthorized shows Retry, which closes then connects again', (
    tester,
  ) async {
    final adb = FakeAdb()..connects.add(AdbResult.unauthorized);
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('instNotAllowed')), findsOneWidget);
    expect(find.text(t('instInstall')), findsNothing);
    adb.log.clear();
    await tester.tap(find.text(t('retry')));
    await tester.pumpAndSettle();
    expect(adb.log.take(2), ['close', 'connect 10.0.0.7:5555']);
    expect(find.text(t('instInstall')), findsOneWidget);
  });

  testWidgets('a shell that never answers times out, closes, offers Retry', (
    tester,
  ) async {
    final adb = FakeAdb(hang: 'getprop ro.product.cpu.abilist');
    await pump(tester, adb);
    await tester.tap(find.text(t('instFireTv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('next')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10.0.0.7'));
    await tester.pump();
    await tester.pump();
    expect(find.text(t('instChecking')), findsOneWidget);
    adb.log.clear();
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(adb.log, ['close']);
    expect(find.text(t('instAdbLost')), findsOneWidget);
    adb.hang = null;
    await tester.tap(find.text(t('retry')));
    await tester.pumpAndSettle();
    expect(adb.log.skip(1).take(2), ['close', 'connect 10.0.0.7:5555']);
    expect(find.text(t('instInstall')), findsOneWidget);
  });

  testWidgets('an x86 TV stops with a message', (tester) async {
    final adb = FakeAdb(abis: 'x86');
    await pump(tester, adb);
    await toConnect(tester);
    expect(
      find.text(t('instBadCpu').replaceAll('{abi}', 'x86')),
      findsOneWidget,
    );
    expect(find.text(t('instInstall')), findsNothing);
    expect(find.text(t('retry')), findsNothing);
    expect(adb.installed, isNull);
  });

  testWidgets('a missing APK for the ABI says so', (tester) async {
    final adb = FakeAdb(abis: 'armeabi-v7a,armeabi');
    await pump(tester, adb, apks: {'assets/tv/ilonatv-arm64-v8a.apk'});
    await toConnect(tester);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    expect(
      find.text(t('instNoApk').replaceAll('{abi}', 'armeabi-v7a')),
      findsOneWidget,
    );
    expect(adb.installed, isNull);
  });

  testWidgets('SDK 33 adds the appops command', (tester) async {
    final adb = FakeAdb(sdk: '33');
    await pump(tester, adb);
    await toConnect(tester);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    final i = adb.log.indexOf(
      'pm grant tv.ilona.app android.permission.PACKAGE_USAGE_STATS',
    );
    expect(
      adb.log[i + 1],
      'appops set tv.ilona.app ACCESS_RESTRICTED_SETTINGS allow',
    );
    expect(find.text(t('instDone')), findsOneWidget);
  });

  testWidgets('an existing package says Update and still installs', (
    tester,
  ) async {
    final adb = FakeAdb(packages: 'package:tv.ilona.app\n');
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('instInstall')), findsNothing);
    await tester.tap(find.text(t('instUpdate')));
    await tester.pumpAndSettle();
    expect(adb.installed, endsWith('ilonatv-arm64-v8a.apk'));
    expect(find.text(t('instDone')), findsOneWidget);
  });

  testWidgets('the Google TV choice shows the README pointer', (tester) async {
    final adb = FakeAdb();
    await pump(tester, adb);
    await tester.tap(find.text(t('instGoogleTv')));
    await tester.pumpAndSettle();
    expect(find.text(t('instUseComputer')), findsOneWidget);
    expect(find.text(readmeUrl), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text(t('instFireTv')), findsOneWidget);
    expect(adb.log, isEmpty);
  });

  testWidgets('Home opens the installer', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tv.ilona.companion/adb'),
          (_) async => null,
        );
    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(tvs: tvs, clientFor: (_) => client),
      ),
    );
    await tester.tap(find.text(t('installOnTv')));
    await tester.pumpAndSettle();
    expect(find.byType(InstallFlow), findsOneWidget);
  });

  group('scan', () {
    test('picks the Wi-Fi IPv4, skipping loopback and VPNs', () {
      expect(
        pickIpv4([
          ('lo', '127.0.0.1'),
          ('tun0', '10.8.0.2'),
          ('rmnet0', '100.64.1.2'),
          ('wlan0', '192.168.1.40'),
        ]),
        '192.168.1.40',
      );
      expect(pickIpv4([('eth0', '192.168.0.9')]), '192.168.0.9');
      expect(pickIpv4([('lo', '127.0.0.1'), ('tun0', '10.8.0.2')]), isNull);
    });

    test('the /24 has 253 other hosts', () {
      final h = subnetHosts('192.168.1.40');
      expect(h, hasLength(253));
      expect(h.first, '192.168.1.1');
      expect(h.last, '192.168.1.254');
      expect(h, isNot(contains('192.168.1.40')));
    });
  });
}
