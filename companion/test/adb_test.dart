import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/adb.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tv.ilona.companion/adb');
  final calls = <MethodCall>[];
  Object? Function(MethodCall) answer = (_) => null;

  setUp(() {
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

  test('shell that fails natively is a non-zero exit with the reason', () async {
    answer = (_) => throw PlatformException(code: 'adb', message: 'closed');
    final r = await Adb().shell('echo');
    expect(r.exitCode, -1);
    expect(r.output, 'closed');
  });

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
}
