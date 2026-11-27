import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
import 'package:ilonatv_companion/desktop/adb.dart';
import 'package:ilonatv_companion/desktop/platform_tools.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeProcesses procs;
  var reachable = true;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('adb');
    File('${dir.path}/platform-tools/adb').createSync(recursive: true);
    procs = FakeProcesses();
    reachable = true;
  });
  tearDown(() => dir.deleteSync(recursive: true));

  DesktopAdb make({
    Duration authWait = const Duration(seconds: 60),
    Duration shellTimeout = const Duration(milliseconds: 50),
  }) => DesktopAdb(
    tools: PlatformTools(
      dir: dir.path,
      os: TargetPlatform.macOS,
      start: procs.start,
      env: const {},
    ),
    reachable: (_, _) async => reachable,
    poll: Duration.zero,
    authWait: authWait,
    shellTimeout: shellTimeout,
  );

  // Every command as its arguments, the adb path dropped.
  List<List<String>> ran() => [for (final c in procs.started) c.sublist(1)];

  Future<DesktopAdb> connected({
    Duration shellTimeout = const Duration(milliseconds: 50),
  }) async {
    final adb = make(shellTimeout: shellTimeout);
    procs.reply = (a) => a.first == 'devices'
        ? (0, 'List of devices attached\n10.0.0.5:5555\tdevice\n\n')
        : null;
    expect(await adb.connect('10.0.0.5', 5555), AdbResult.ok);
    procs.started.clear();
    procs.live.clear();
    procs.reply = (_) => null;
    return adb;
  }

  group('parsing', () {
    test('adb devices', () {
      expect(
        parseDevices(
          '* daemon not running; starting now at tcp:5037\n'
          '* daemon started successfully\n'
          'List of devices attached\n'
          '10.0.0.5:5555\tunauthorized\n'
          'emulator-5554\tdevice\n'
          'adb-X._adb-tls-connect._tcp\toffline\n\n',
        ),
        {
          '10.0.0.5:5555': 'unauthorized',
          'emulator-5554': 'device',
          'adb-X._adb-tls-connect._tcp': 'offline',
        },
      );
      expect(parseDevices('List of devices attached\n\n'), isEmpty);
    });

    test('adb connect', () {
      for (final (out, failed) in [
        ('connected to 10.0.0.5:5555\n', false),
        ('already connected to 10.0.0.5:5555\n', false),
        // The TV's prompt is up: adb keeps the connection and waits.
        ('failed to authenticate to 10.0.0.5:5555\n', false),
        ("failed to connect to '10.0.0.5:5555': Connection refused\n", true),
        ('cannot connect to 10.0.0.5:5555: No route to host (65)\n', true),
      ]) {
        expect(connectFailed(out), failed, reason: out);
      }
    });

    test('adb pair', () {
      expect(
        pairFailure('Successfully paired to 10.0.0.5:37000 [guid=adb-X]\n'),
        isNull,
      );
      expect(
        pairFailure('Failed: Wrong password or connection was dropped.\n'),
        'Failed: Wrong password or connection was dropped.',
      );
      expect(pairFailure(''), isNotNull);
    });
  });

  test('a TV with nothing on the port is unreachable, adb untouched', () async {
    reachable = false;
    expect(await make().connect('10.0.0.5', 5555), AdbResult.unreachable);
    expect(procs.started, isEmpty);
  });

  test('connect waits out the TV prompt, polling adb devices', () async {
    final adb = make();
    var polls = 0;
    procs.reply = (a) {
      if (a.first == 'connect') return (1, 'failed to authenticate to x\n');
      if (++polls < 3) return (0, 'List\n10.0.0.5:5555\tunauthorized\n');
      return (0, 'List\n10.0.0.5:5555\tdevice\n');
    };
    expect(await adb.connect('10.0.0.5', 5555), AdbResult.ok);
    expect(ran(), [
      ['connect', '10.0.0.5:5555'],
      ['devices'],
      ['devices'],
      ['devices'],
    ]);
  });

  test('a refused connect is unreachable', () async {
    procs.reply = (a) => (1, "failed to connect to '10.0.0.5:5555': refused");
    expect(await make().connect('10.0.0.5', 5555), AdbResult.unreachable);
  });

  test('a prompt never answered is unauthorized', () async {
    procs.reply = (a) => (0, 'List\n10.0.0.5:5555\tunauthorized\n');
    expect(
      await make(authWait: const Duration(milliseconds: 20))
          .connect('10.0.0.5', 5555),
      AdbResult.unauthorized,
    );
  });

  test('shell sends the command as one argument to the TV', () async {
    final adb = await connected();
    procs.reply = (_) => (0, '    versionName=0.6.1\n');
    final r = await adb.shell(
      'dumpsys package tv.ilona.app | grep versionName',
    );
    expect(r.exitCode, 0);
    expect(r.output, '    versionName=0.6.1\n');
    expect(ran().single, [
      '-s',
      '10.0.0.5:5555',
      'shell',
      'dumpsys package tv.ilona.app | grep versionName',
    ]);
  });

  test('a command that fails on the TV keeps its exit code', () async {
    final adb = await connected();
    procs.reply = (_) => (255, 'Security exception: not allowed\n');
    expect((await adb.shell('pm grant x y')).exitCode, 255);
  });

  test('a lost device is -1, like a dropped connection on Android', () async {
    final adb = await connected();
    for (final out in [
      "adb: device '10.0.0.5:5555' not found\n",
      "error: device '10.0.0.5:5555' not found\n",
      'error: device offline\n',
      'error: closed\n',
    ]) {
      procs.reply = (_) => (1, out);
      expect((await adb.shell('echo')).exitCode, -1, reason: out);
    }
  });

  test('shell before connect is -1 and runs nothing', () async {
    expect((await make().shell('echo')).exitCode, -1);
    expect(procs.started, isEmpty);
  });

  test('a command that hangs is killed at its timeout', () async {
    final adb = await connected();
    procs.hangs = (_) => true;
    final r = await adb.shell('sleep 999');
    expect(r.exitCode, -1);
    expect(procs.live.last.killed, isTrue);
  });

  test('keys go through one shell kept open, as int lines', () async {
    final adb = await connected();
    procs.hangs = (a) => a.last == 'shell';
    expect(await adb.key(22), isTrue);
    expect(await adb.key(23), isTrue);
    expect(ran(), [
      ['-s', '10.0.0.5:5555', 'shell'],
    ]);
    expect(
      procs.live.single.written.join(),
      'exec >/dev/null 2>&1\ninput keyevent 22\ninput keyevent 23\n',
    );
  });

  test('a key code outside Android\'s range is refused', () async {
    final adb = await connected();
    procs.hangs = (a) => a.last == 'shell';
    for (final code in [-1, 1000, 1 << 40]) {
      expect(await adb.key(code), isFalse, reason: '$code');
    }
    expect(procs.started, isEmpty);
  });

  test('a shell that died gets one fresh one', () async {
    final adb = await connected();
    procs.hangs = (a) => a.last == 'shell';
    expect(await adb.key(19), isTrue);
    procs.live.single.die();
    expect(await adb.key(20), isTrue);
    expect(ran(), hasLength(2));
    expect(procs.live.last.written.last, 'input keyevent 20\n');
  });

  test(
    'install -r with the path apart; adb\'s failure is the reason',
    () async {
      final adb = await connected();
      procs.reply = (_) => (0, 'Performing Streamed Install\nSuccess\n');
      expect(await adb.install('/tmp/my files/ilonatv.apk'), isNull);
      expect(ran().single, [
        '-s',
        '10.0.0.5:5555',
        'install',
        '-r',
        '/tmp/my files/ilonatv.apk',
      ]);
      procs.reply = (_) => (
        1,
        'adb: failed to install x.apk: Failure [INSTALL_FAILED_VERSION_DOWNGRADE]\n',
      );
      expect(
        await adb.install('/tmp/x.apk'),
        contains('INSTALL_FAILED_VERSION_DOWNGRADE'),
      );
    },
  );

  test('pair sends host:port and the code; only six digits go', () async {
    final adb = make();
    procs.reply = (_) =>
        (0, 'Successfully paired to 10.0.0.5:37000 [guid=x]\n');
    expect(await adb.pair('10.0.0.5', 37000, '123456'), isNull);
    expect(ran().where((a) => a.first != 'version').single, [
      'pair',
      '10.0.0.5:37000',
      '123456',
    ]);
    procs.reply = (_) =>
        (1, 'Failed: Wrong password or connection was dropped.\n');
    expect(await adb.pair('10.0.0.5', 37000, '123456'), startsWith('Failed'));
    procs.started.clear();
    for (final bad in ['12345', '1234567', '12 456', '-s x']) {
      expect(await adb.pair('10.0.0.5', 37000, bad), isNotNull);
    }
    expect(procs.started, isEmpty);
  });

  test('close ends the key shell and disconnects', () async {
    final adb = await connected();
    procs.hangs = (a) => a.last == 'shell';
    await adb.key(3);
    final shell = procs.live.single;
    procs.hangs = (_) => false;
    await adb.close();
    expect(shell.killed, isTrue);
    expect(ran().last, ['disconnect', '10.0.0.5:5555']);
    expect((await adb.shell('echo')).exitCode, -1);
  });

  test('close kills what is still running; it answers -1', () async {
    final adb = await connected(shellTimeout: const Duration(minutes: 1));
    procs.hangs = (a) => a.last == 'sleep 999';
    final shell = adb.shell('sleep 999');
    await Future<void>.delayed(Duration.zero);
    procs.hangs = (_) => false;
    await adb.close();
    expect(procs.live.first.killed, isTrue);
    expect((await shell).exitCode, -1);
  });

  test('pairing uses an adb new enough to pair', () async {
    final bin = Directory.systemTemp.createTempSync('bin');
    addTearDown(() => bin.deleteSync(recursive: true));
    File('${bin.path}/adb').createSync();
    final adb = DesktopAdb(
      tools: PlatformTools(
        dir: dir.path,
        os: TargetPlatform.macOS,
        start: procs.start,
        env: {'PATH': bin.path},
      ),
    );
    procs.reply = (a) => a.first == 'version'
        ? (0, 'Android Debug Bridge version 1.0.41\nVersion 29.0.6-1\n')
        : (0, 'Successfully paired to 10.0.0.5:37000 [guid=x]\n');
    expect(await adb.canPair(), isTrue);
    expect(await adb.pair('10.0.0.5', 37000, '123456'), isNull);
    expect(procs.started.last, [
      '${dir.path}/platform-tools/adb',
      'pair',
      '10.0.0.5:37000',
      '123456',
    ]);
    expect(adb.ready, isTrue);
  });

  test('without adb, ready is false and connect runs nothing', () async {
    File('${dir.path}/platform-tools/adb').deleteSync();
    final adb = DesktopAdb(
      tools: PlatformTools(
        dir: dir.path,
        os: TargetPlatform.windows,
        start: procs.start,
        env: const {},
      ),
      reachable: (_, _) async => true,
    );
    expect(adb.ready, isFalse);
    expect(await adb.connect('10.0.0.5', 5555), AdbResult.unreachable);
    expect(procs.started, isEmpty);
  });

  group('Adb on desktop', () {
    final calls = <String>[];
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('tv.ilona.companion/adb'),
            (c) async {
              calls.add(c.method);
              return null;
            },
          );
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('runs adb itself and remembers a TV that allowed it', () async {
      procs.reply = (a) =>
          a.first == 'devices' ? (0, 'List\n10.0.0.5:5555\tdevice\n') : null;
      final adb = Adb(make());
      expect(await adb.connect('10.0.0.5', 5555), AdbResult.ok);
      expect(await adb.knows('10.0.0.5'), isTrue);
      procs.hangs = (a) => a.last == 'shell';
      expect(await adb.key(RemoteKey.right), isTrue);
      expect(procs.live.last.written.last, 'input keyevent 22\n');
      expect(calls, isEmpty);
    });

    test('is picked by itself on macOS and Windows', () async {
      for (final os in [TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = os;
        // Not connected: false straight away, and the channel never asked.
        expect(await Adb().key(RemoteKey.ok), isFalse);
      }
      expect(calls, isEmpty);
    });
  });
}
