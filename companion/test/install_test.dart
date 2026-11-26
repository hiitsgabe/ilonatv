import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/releases.dart';
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
    this.secret = _secret,
    this.version,
  });
  final String sdk, abis, packages, secret;
  final String? version;
  String? hang;
  final log = <String>[];
  final connects = <AdbResult>[];
  String? installed;
  String? installError;

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
      'dumpsys package tv.ilona.app | grep versionName' =>
        version == null ? '' : '    versionName=$version\n',
      'content query --uri content://tv.ilona.app.pairing/secret' =>
        'Row: 0 secret=$secret\n',
      _ => '',
    };
    return ShellResult(0, out);
  }

  @override
  Future<String?> install(String path) async {
    log.add(
      'install ${path.split('/').last.replaceFirst(RegExp(r'-\d+\.apk$'), '.apk')}',
    );
    installed = path;
    return installError;
  }

  @override
  Future<void> close() async => log.add('close');
}

class FakeClient extends TvClient {
  FakeClient() : super('10.0.0.7');
  String? secret, name;
  TvResult<TvInfo> infoResult = const Unpaired();

  @override
  Future<TvResult<TvInfo>> info() async => infoResult;

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

class FakeReleases extends ReleaseSource {
  FakeReleases({this.abis = const {'arm64-v8a', 'armeabi-v7a'}});
  final Set<String> abis;
  String? version = 'v0.6.1';
  Object? latestError;
  final fetchErrors = <Object>[];
  Completer<void>? gate;
  final fetched = <String>[];

  @override
  Future<ReleaseAsset?> latest(String abi) async {
    if (latestError case final e?) throw e;
    if (version == null) return null;
    if (!abis.contains(abi)) throw const NoAsset();
    return ReleaseAsset(
      url: Uri.parse('https://example.test/ilonatv-$abi.apk'),
      size: 3 << 20,
      version: version!,
      sha256: '',
    );
  }

  @override
  Future<File> fetch(
    ReleaseAsset a,
    File to, {
    void Function(int received, int total)? progress,
  }) async {
    fetched.add(a.url.pathSegments.last);
    if (fetchErrors.isNotEmpty) throw fetchErrors.removeAt(0);
    progress?.call(1 << 20, a.size);
    await gate?.future;
    to.writeAsBytesSync([1, 2, 3]);
    return to;
  }
}

void main() {
  late Tvs tvs;
  late FakeClient client;
  late FakeReleases releases;

  setUp(() {
    releases = FakeReleases();
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
    Stream<String> Function()? scan,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: InstallFlow(
          adb: adb,
          tvs: tvs,
          releases: releases,
          clientFor: (_) => client,
          scan: scan ?? () => Stream.value('10.0.0.7'),
        ),
      ),
    );
  }

  Future<void> toConnect(
    WidgetTester tester, [
    String kind = 'instFireTv',
  ]) async {
    await tester.tap(find.text(t(kind)));
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
    expect(
      find.text(t('instRelease').replaceAll('{version}', 'v0.6.1')),
      findsOneWidget,
    );
    expect(find.text(t('instFresh')), findsOneWidget);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();

    expect(find.text(t('instDoneFire')), findsOneWidget);
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

  testWidgets('a release without the ABI asset stops at Check', (tester) async {
    releases = FakeReleases(abis: {'arm64-v8a'});
    final adb = FakeAdb(abis: 'armeabi-v7a,armeabi');
    await pump(tester, adb);
    await toConnect(tester);
    expect(
      find.text(t('instNoApk').replaceAll('{abi}', 'armeabi-v7a')),
      findsOneWidget,
    );
    expect(find.text(t('instInstall')), findsNothing);
    expect(find.text(t('retry')), findsNothing);
    expect(releases.fetched, isEmpty);
  });

  testWidgets('no release yet points to the README, without Retry', (
    tester,
  ) async {
    releases.version = null;
    final adb = FakeAdb();
    await pump(tester, adb);
    await toConnect(tester);
    expect(
      find.text(t('instNoRelease').replaceAll('{url}', readmeUrl)),
      findsOneWidget,
    );
    expect(find.text(t('retry')), findsNothing);
    expect(find.text(t('instInstall')), findsNothing);
  });

  testWidgets('GitHub unreachable at Check offers Retry', (tester) async {
    releases.latestError = const SocketException('no network');
    final adb = FakeAdb();
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('instOffline')), findsOneWidget);
    releases.latestError = null;
    await tester.tap(find.text(t('retry')));
    await tester.pumpAndSettle();
    expect(
      find.text(t('instRelease').replaceAll('{version}', 'v0.6.1')),
      findsOneWidget,
    );
    expect(find.text(t('instInstall')), findsOneWidget);
  });

  testWidgets('GitHub limiting requests has its own message, with Retry', (
    tester,
  ) async {
    releases.latestError = const RateLimited();
    await pump(tester, FakeAdb());
    await toConnect(tester);
    expect(find.text(t('instRateLimited')), findsOneWidget);
    expect(find.text(t('instOffline')), findsNothing);
    expect(find.text(t('retry')), findsOneWidget);
  });

  testWidgets('the download shows MB of MB, then installs', (tester) async {
    releases.gate = Completer();
    final adb = FakeAdb();
    await pump(tester, adb);
    await toConnect(tester);
    await tester.tap(find.text(t('instInstall')));
    await tester.pump();
    await tester.pump();
    expect(
      find.text(t('instDownloading').replaceAll('{version}', 'v0.6.1')),
      findsOneWidget,
    );
    expect(
      find.text(
        t('instMbOf').replaceAll('{got}', '1.0').replaceAll('{total}', '3.0'),
      ),
      findsOneWidget,
    );
    expect(adb.installed, isNull);
    releases.gate!.complete();
    await tester.pumpAndSettle();
    expect(releases.fetched, ['ilonatv-arm64-v8a.apk']);
    expect(adb.installed, contains('ilonatv-arm64-v8a'));
    expect(File(adb.installed!).existsSync(), isFalse);
    expect(find.text(t('instDoneFire')), findsOneWidget);
  });

  for (final (name, error, key) in [
    ('a checksum mismatch', const BadChecksum(), 'instBadChecksum'),
    ('a lost download', const SocketException('reset'), 'instOffline'),
  ]) {
    testWidgets('$name shows $key, and Retry downloads again', (tester) async {
      releases.fetchErrors.add(error);
      final adb = FakeAdb();
      await pump(tester, adb);
      await toConnect(tester);
      await tester.tap(find.text(t('instInstall')));
      await tester.pumpAndSettle();
      expect(find.text(t(key)), findsOneWidget);
      expect(adb.installed, isNull);
      await tester.tap(find.text(t('retry')));
      await tester.pumpAndSettle();
      expect(releases.fetched, hasLength(2));
      expect(find.text(t('instDoneFire')), findsOneWidget);
    });
  }

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
    expect(find.text(t('instDoneFire')), findsOneWidget);
  });

  testWidgets('an older Ilona TV on the TV says Update and installs', (
    tester,
  ) async {
    final adb = FakeAdb(packages: 'package:tv.ilona.app\n', version: '0.6.0');
    await pump(tester, adb);
    await toConnect(tester);
    expect(
      adb.log,
      contains('dumpsys package tv.ilona.app | grep versionName'),
    );
    expect(find.text(t('instExisting')), findsOneWidget);
    expect(find.text(t('instInstall')), findsNothing);
    await tester.tap(find.text(t('instUpdate')));
    await tester.pumpAndSettle();
    expect(adb.installed, contains('ilonatv-arm64-v8a'));
    expect(find.text(t('instDoneFire')), findsOneWidget);
  });

  for (final version in ['0.6.1', '0.7.0']) {
    testWidgets('Ilona TV $version on the TV skips to pairing by default', (
      tester,
    ) async {
      final adb = FakeAdb(packages: 'package:tv.ilona.app\n', version: version);
      await pump(tester, adb);
      await toConnect(tester);
      expect(
        find.text(t('instUpToDate').replaceAll('{version}', version)),
        findsOneWidget,
      );
      expect(find.text(t('instUpdate')), findsNothing);
      expect(find.text(t('instReinstall')), findsOneWidget);
      await tester.tap(find.text(t('next')));
      await tester.pumpAndSettle();
      expect(find.text(t('instDoneFire')), findsOneWidget);
      expect(releases.fetched, isEmpty);
      expect(adb.installed, isNull);
      expect(adb.log.where((l) => l.startsWith('pm grant')), isEmpty);
      expect(tvs.all.single.token, 'tok');
    });
  }

  testWidgets('Reinstall on the same version downloads and installs', (
    tester,
  ) async {
    final adb = FakeAdb(packages: 'package:tv.ilona.app\n', version: '0.6.1');
    await pump(tester, adb);
    await toConnect(tester);
    await tester.tap(find.text(t('instReinstall')));
    await tester.pumpAndSettle();
    expect(releases.fetched, ['ilonatv-arm64-v8a.apk']);
    expect(adb.installed, contains('ilonatv-arm64-v8a'));
    expect(find.text(t('instDoneFire')), findsOneWidget);
  });

  testWidgets('an SDK that does not parse goes on to install', (tester) async {
    final adb = FakeAdb(sdk: '');
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('instOldAndroid')), findsNothing);
    expect(
      find.text(
        t('instTvSummary')
            .replaceAll('{sdk}', '?')
            .replaceAll('{abi}', 'arm64-v8a'),
      ),
      findsOneWidget,
    );
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    expect(adb.installed, isNotNull);
    expect(adb.log.where((l) => l.startsWith('appops')), isEmpty);
    expect(find.text(t('instDoneFire')), findsOneWidget);
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

  testWidgets('after a failed connect, Back and a bad IP show Connect', (
    tester,
  ) async {
    final adb = FakeAdb()..connects.add(AdbResult.unauthorized);
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('retry')), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'not an ip');
    await tester.tap(find.text(t('instConnect')).last);
    await tester.pumpAndSettle();
    expect(find.text(t('badAddress')), findsOneWidget);
    expect(find.text(t('retry')), findsNothing);
    expect(find.widgetWithText(FilledButton, t('instConnect')), findsOneWidget);
  });

  testWidgets('unreachable names the port that was tried', (tester) async {
    final adb = FakeAdb()..connects.add(AdbResult.unreachable);
    await pump(tester, adb);
    await tester.tap(find.text(t('instFireTv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('next')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '10.0.0.9:5556');
    await tester.tap(find.text(t('instConnect')).last);
    await tester.pumpAndSettle();
    expect(
      find.text(t('instNoAdb').replaceAll('{host}', '10.0.0.9:5556')),
      findsOneWidget,
    );
  });

  for (final (name, hang) in [
    ('Check', null),
    ('Start and pair', 'am start -n tv.ilona.app/.MainActivity'),
  ]) {
    testWidgets('Back during $name closes ADB and returns to Find', (
      tester,
    ) async {
      final adb = FakeAdb(hang: hang);
      await pump(tester, adb);
      await toConnect(tester);
      if (hang != null) {
        await tester.tap(find.text(t('instInstall')));
        await tester.pump();
        await tester.pump();
        expect(find.text(t('instStarting')), findsOneWidget);
      }
      adb.log.clear();
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(adb.log, ['close']);
      expect(find.text(t('instFindTitle')), findsOneWidget);
      expect(find.text('10.0.0.7'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(adb.log, ['close'], reason: 'a stale timeout closes nothing');
    });
  }

  testWidgets('no secret yet shows instNoSecret with Retry', (tester) async {
    final adb = FakeAdb(secret: 'NULL');
    await pump(tester, adb);
    await toConnect(tester);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    expect(find.text(t('instNoSecret')), findsOneWidget);
    expect(find.text(t('retry')), findsOneWidget);
    expect(tvs.all, isEmpty);
  });

  testWidgets('a scan that fails leaves the type-the-IP path', (tester) async {
    await pump(
      tester,
      FakeAdb(),
      scan: () => Stream.error(const SocketException('no network')),
    );
    await tester.tap(find.text(t('instFireTv')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('next')));
    await tester.pumpAndSettle();
    expect(find.text(t('instNoneFound')), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
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

  testWidgets('Android TV ends with its own menu path', (tester) async {
    final adb = FakeAdb();
    await pump(tester, adb);
    await toConnect(tester, 'instAndroidTv');
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    expect(find.text(t('instDoneAndroid')), findsOneWidget);
    expect(find.text(t('instDoneFire')), findsNothing);
  });

  testWidgets('a TV below Android 9 stops without Retry', (tester) async {
    final adb = FakeAdb(sdk: '27');
    await pump(tester, adb);
    await toConnect(tester);
    expect(find.text(t('instOldAndroid')), findsOneWidget);
    expect(find.text(t('instInstall')), findsNothing);
    expect(find.text(t('retry')), findsNothing);
  });

  for (final (code, key) in [
    ('INSTALL_FAILED_UPDATE_INCOMPATIBLE', 'instSignedOther'),
    ('INSTALL_FAILED_VERSION_DOWNGRADE', 'instDowngrade'),
    ('INSTALL_FAILED_OLDER_SDK', 'instOldAndroid'),
  ]) {
    testWidgets('$code has its own message and no Retry', (tester) async {
      final adb = FakeAdb()
        ..installError = 'Failure [$code: Package tv.ilona.app x]';
      await pump(tester, adb);
      await toConnect(tester);
      await tester.tap(find.text(t('instInstall')));
      await tester.pumpAndSettle();
      expect(find.text(t(key)), findsOneWidget);
      expect(find.text(t('retry')), findsNothing);
    });
  }

  testWidgets('a TV this phone is already paired with is not paired again', (
    tester,
  ) async {
    await tvs.savePaired(
      Tv(host: '10.0.0.7', port: 8642, name: 'Living'),
      'old',
    );
    client.infoResult = const Ok(
      TvInfo(protocol: 1, version: '1', inFront: true, launcherMode: true),
    );
    final adb = FakeAdb();
    await pump(tester, adb);
    await toConnect(tester);
    await tester.tap(find.text(t('instInstall')));
    await tester.pumpAndSettle();
    expect(find.text(t('instDoneFire')), findsOneWidget);
    expect(adb.log.where((l) => l.startsWith('content query')), isEmpty);
    expect(client.secret, isNull);
    expect(tvs.all.single.token, 'old');
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
