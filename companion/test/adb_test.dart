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
      RemoteKey.mute: 164,
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

  testWidgets('a key with no answer in 3 s is false', (tester) async {
    answer = (_) => Completer<void>().future;
    bool? got;
    Adb().key(RemoteKey.up).then((r) => got = r);
    await tester.pump(const Duration(seconds: 2));
    expect(got, isNull);
    await tester.pump(const Duration(seconds: 2));
    expect(got, isFalse);
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
      RemoteKey.mute,
      RemoteKey.playPause,
    ];
    const all = RemoteKey.values;
    const nav = [...dpad, RemoteKey.back, RemoteKey.home];

    bool use(RemoteKey k, bool inFront, String? o, {bool up = false}) =>
        useAdb(k, inFront: inFront, keysOutside: o, adbUp: up);

    test('the D-pad never while Ilona TV is in front, even on an older TV', () {
      for (final o in ['all', 'backHome', 'none', null]) {
        for (final k in nav) {
          expect(use(k, true, o), isFalse);
          expect(use(k, true, o, up: true), isFalse);
        }
      }
    });

    test('another app in front: only what the TV cannot do itself', () {
      for (final k in nav) {
        expect(use(k, false, 'all'), isFalse);
        expect(use(k, false, 'none'), isTrue);
        expect(use(k, false, null), isTrue);
      }
      for (final k in dpad) {
        expect(use(k, false, 'backHome'), isTrue);
      }
      for (final k in [RemoteKey.back, RemoteKey.home]) {
        expect(use(k, false, 'backHome'), isFalse);
      }
    });

    test('media over ADB only while it is up on a TV without API 33 actions, '
        'so volume goes through the system (CEC)', () {
      for (final k in media) {
        for (final inFront in [true, false]) {
          expect(use(k, inFront, 'backHome', up: true), isTrue);
          expect(use(k, inFront, 'none', up: true), isTrue);
          expect(use(k, inFront, 'backHome'), isFalse);
          expect(use(k, inFront, 'all', up: true), isFalse);
          expect(use(k, inFront, null, up: true), !inFront);
        }
      }
      expect(all.length, nav.length + media.length);
    });
  });
}
