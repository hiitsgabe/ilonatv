import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tv.ilona.companion/host');
  final calls = <String>[];

  Future<void> native(String method, Map<String, Object?> args) async {
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
          calls.add(c.method);
          return null;
        });
  });

  Future<Tvs> make() async {
    final tvs = Tvs();
    await tvs.load();
    tvs.startDiscovery();
    return tvs;
  }

  test('a found TV is listed unpaired and lost removes it', () async {
    final tvs = await make();
    await native('found', {
      'name': 'Ilona TV on X',
      'host': '10.0.0.5',
      'port': 8642,
    });
    expect(tvs.all.single.token, isNull);
    expect(tvs.all.single.found, isTrue);
    await native('lost', {'name': 'Ilona TV on X'});
    expect(tvs.all, isEmpty);
    tvs.stopDiscovery();
    expect(calls, ['discoverStart', 'discoverStop']);
  });

  test('savePaired persists and a reload keeps it', () async {
    final tvs = await make();
    await tvs.savePaired(
      Tv(host: '10.0.0.5', port: 8642, name: 'Living'),
      'tok',
    );
    final again = Tvs();
    await again.load();
    expect(again.all.single.token, 'tok');
    expect(again.all.single.found, isFalse);
  });

  test('the same host found and paired appears once, paired', () async {
    final tvs = await make();
    await tvs.savePaired(
      Tv(host: '10.0.0.5', port: 8642, name: 'Living'),
      'tok',
    );
    await native('found', {
      'name': 'Ilona TV on X',
      'host': '10.0.0.5',
      'port': 8642,
    });
    expect(tvs.all.length, 1);
    expect(tvs.all.single.token, 'tok');
    expect(tvs.all.single.found, isTrue);
  });

  test('paired come before found-unpaired', () async {
    final tvs = await make();
    await native('found', {'name': 'A', 'host': '10.0.0.1', 'port': 8642});
    await tvs.savePaired(Tv(host: '10.0.0.2', port: 8642, name: 'B'), 'tok');
    expect(tvs.all.map((t) => t.host), ['10.0.0.2', '10.0.0.1']);
  });

  test('forget removes it, also from storage', () async {
    final tvs = await make();
    await tvs.savePaired(
      Tv(host: '10.0.0.5', port: 8642, name: 'Living'),
      'tok',
    );
    await tvs.forget('10.0.0.5');
    expect(tvs.all, isEmpty);
    final again = Tvs();
    await again.load();
    expect(again.all, isEmpty);
  });

  test('forget keeps a TV that is still on the network, unpaired', () async {
    final tvs = await make();
    await native('found', {'name': 'A', 'host': '10.0.0.1', 'port': 8642});
    await tvs.savePaired(Tv(host: '10.0.0.1', port: 8642, name: 'A'), 'tok');
    await tvs.forget('10.0.0.1');
    expect(tvs.all.single.token, isNull);
  });

  test('unparseable saved data loads as no TVs', () async {
    SharedPreferences.setMockInitialValues({'tvs': 'x{'});
    final tvs = Tvs();
    await tvs.load();
    expect(tvs.all, isEmpty);
  });

  test('a bad entry is skipped, the good ones stay', () async {
    SharedPreferences.setMockInitialValues({
      'tvs': '[{"host":"h"},5,{"host":"10.0.0.9","port":8642,"name":"N","token":"t"}]',
    });
    final tvs = Tvs();
    await tvs.load();
    expect(tvs.all.map((t) => t.host), ['10.0.0.9']);
  });

  test('a non-list value loads as no TVs', () async {
    SharedPreferences.setMockInitialValues({'tvs': '{"a":1}'});
    final tvs = Tvs();
    await tvs.load();
    expect(tvs.all, isEmpty);
  });
}
