import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tv.ilona.companion/adb');
  final calls = <MethodCall>[];
  Object? Function(MethodCall) answer = (_) => null;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    answer = (_) => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
          calls.add(c);
          final a = answer(c);
          if (a is Future) return await a;
          return a;
        });
  });

  test('connect sends host and port and maps each answer', () async {
    for (final (native, expected) in [
      ('ok', AdbResult.ok),
      ('unauthorized', AdbResult.unauthorized),
      ('unreachable', AdbResult.unreachable),
    ]) {
      answer = (_) => native;
      expect(await Adb().connect('192.168.1.5', 5555), expected);
    }
    expect(calls.first.method, 'connect');
    expect(calls.first.arguments, {'host': '192.168.1.5', 'port': 5555});
  });

  test('connect that fails natively is unreachable', () async {
    answer = (_) => throw PlatformException(code: 'adb');
    expect(await Adb().connect('h', 5555), AdbResult.unreachable);
  });

  testWidgets('connect still unanswered after the wait is unauthorized', (
    tester,
  ) async {
    answer = (_) => Completer<String>().future;
    AdbResult? got;
    Adb().connect('h', 5555).then((r) => got = r);
    await tester.pump(const Duration(seconds: 59));
    expect(got, isNull);
    await tester.pump(const Duration(seconds: 10));
    expect(got, AdbResult.unauthorized);
  });

  test('shell sends the command and returns exit code and output', () async {
    answer = (_) => {'exitCode': 0, 'output': 'arm64-v8a,armeabi-v7a\n'};
    final r = await Adb().shell('getprop ro.product.cpu.abilist');
    expect(calls.single.method, 'shell');
    expect(calls.single.arguments, {'cmd': 'getprop ro.product.cpu.abilist'});
    expect(r.exitCode, 0);
    expect(r.output, 'arm64-v8a,armeabi-v7a\n');
  });

  test(
    'shell that fails natively is a non-zero exit with the reason',
    () async {
      answer = (_) => throw PlatformException(code: 'adb', message: 'closed');
      final r = await Adb().shell('echo');
      expect(r.exitCode, -1);
      expect(r.output, 'closed');
    },
  );

  test('install gives null on ok and the error otherwise', () async {
    answer = (_) => 'ok';
    expect(await Adb().install('/data/x.apk'), isNull);
    expect(calls.single.method, 'install');
    expect(calls.single.arguments, {'path': '/data/x.apk'});
    answer = (_) => {'error': 'INSTALL_FAILED_INSUFFICIENT_STORAGE'};
    expect(
      await Adb().install('/data/x.apk'),
      'INSTALL_FAILED_INSUFFICIENT_STORAGE',
    );
    answer = (_) => throw PlatformException(code: 'adb', message: 'closed');
    expect(await Adb().install('/data/x.apk'), 'closed');
  });

  test('close is sent', () async {
    await Adb().close();
    expect(calls.single.method, 'close');
  });

  test('every key has its Android keycode', () {
    expect(adbKeycodes, {
      RemoteKey.up: 19,
      RemoteKey.down: 20,
      RemoteKey.left: 21,
      RemoteKey.right: 22,
      RemoteKey.ok: 23,
      RemoteKey.back: 4,
      RemoteKey.home: 3,
      RemoteKey.volumeUp: 24,
      RemoteKey.volumeDown: 25,
      RemoteKey.playPause: 85,
    });
    expect(adbKeycodes.keys, containsAll(RemoteKey.values));
  });

  test('key sends the keycode; false when the shell fails', () async {
    answer = (_) => null;
    expect(await Adb().key(RemoteKey.right), isTrue);
    expect(calls.single.method, 'key');
    expect(calls.single.arguments, {'code': 22});
    answer = (_) => throw PlatformException(code: 'adb', message: 'closed');
    expect(await Adb().key(RemoteKey.ok), isFalse);
  });

  test('a TV is known once a connect to it took', () async {
    answer = (_) => 'unauthorized';
    await Adb().connect('10.0.0.2', 5555);
    expect(await Adb().knows('10.0.0.2'), isFalse);
    answer = (_) => 'ok';
    await Adb().connect('10.0.0.2', 5555);
    expect(await Adb().knows('10.0.0.2'), isTrue);
    expect(await Adb().knows('10.0.0.3'), isFalse);
  });

  group('useAdb', () {
    const dpad = [
      RemoteKey.up,
      RemoteKey.down,
      RemoteKey.left,
      RemoteKey.right,
      RemoteKey.ok,
    ];
    const media = [
      RemoteKey.volumeUp,
      RemoteKey.volumeDown,
      RemoteKey.playPause,
    ];
    const all = RemoteKey.values;

    test('never while Ilona TV is in front, but for media on an older TV', () {
      for (final o in ['all', 'backHome', 'none']) {
        for (final k in all) {
          expect(useAdb(k, inFront: true, keysOutside: o), isFalse);
        }
      }
      for (final k in all) {
        expect(useAdb(k, inFront: true, keysOutside: null), media.contains(k));
      }
    });

    test('another app in front: only what the TV cannot do itself', () {
      for (final k in all) {
        expect(useAdb(k, inFront: false, keysOutside: 'all'), isFalse);
        expect(
          useAdb(k, inFront: false, keysOutside: 'none'),
          !media.contains(k),
        );
        expect(useAdb(k, inFront: false, keysOutside: null), isTrue);
      }
      for (final k in dpad) {
        expect(useAdb(k, inFront: false, keysOutside: 'backHome'), isTrue);
      }
      for (final k in [RemoteKey.back, RemoteKey.home, ...media]) {
        expect(useAdb(k, inFront: false, keysOutside: 'backHome'), isFalse);
      }
    });
  });
}
