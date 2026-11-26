import 'dart:math';

import 'package:elimor/companion/pairing.dart';
import 'package:elimor/settings.dart';
import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<(Settings, Pairing)> make() async {
    final s = await Settings.load();
    return (s, Pairing(s, random: Random(1)));
  }

  String wrong(Pairing p) => p.code == '000000' ? '000001' : '000000';

  test('pairs with the secret and stores the device', () async {
    final (s, p) = await make();
    final token = await p.pair(
      PairRequest(secret: s.companionSecret, name: 'Mac'),
    );
    expect(token, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(s.companionDevices[token], 'Mac');
    expect((await Settings.load()).companionDevices[token], 'Mac');
    expect(p.isValid(token!), isTrue);
  });

  test('a wrong secret does not pair', () async {
    final (_, p) = await make();
    expect(await p.pair(PairRequest(secret: 'x' * 32, name: 'Mac')), isNull);
    expect(await p.pair(PairRequest(name: 'Mac')), isNull);
  });

  test('the code is 6 digits', () async {
    final (_, p) = await make();
    expect(p.code, matches(RegExp(r'^\d{6}$')));
  });

  test('pairs with the code once', () async {
    final (_, p) = await make();
    final code = p.code;
    expect(await p.pair(PairRequest(code: code, name: 'A')), isNotNull);
    expect(p.code, isNot(code));
    expect(await p.pair(PairRequest(code: code, name: 'B')), isNull);
  });

  test('five wrong codes replace the code', () async {
    final (_, p) = await make();
    final old = p.code;
    final bad = wrong(p);
    for (var i = 0; i < 5; i++) {
      expect(await p.pair(PairRequest(code: bad, name: 'X')), isNull);
    }
    expect(p.code, isNot(old));
    expect(await p.pair(PairRequest(code: old, name: 'X')), isNull);
  });

  test('four wrong codes keep the code', () async {
    final (_, p) = await make();
    final old = p.code;
    final bad = wrong(p);
    for (var i = 0; i < 4; i++) {
      await p.pair(PairRequest(code: bad, name: 'X'));
    }
    expect(p.code, old);
  });

  test('remove revokes and notifies', () async {
    final (s, p) = await make();
    final token = (await p.pair(
      PairRequest(secret: s.companionSecret, name: 'Mac'),
    ))!;
    var calls = 0;
    p.addListener(() => calls++);
    await p.remove(token);
    expect(p.isValid(token), isFalse);
    expect(calls, 1);
    expect((await Settings.load()).companionDevices, isEmpty);
  });

  test(
    'renewSecret changes the secret, notifies, and old secret fails',
    () async {
      final (s, p) = await make();
      final old = s.companionSecret;
      var calls = 0;
      p.addListener(() => calls++);
      await p.renewSecret();
      expect(p.secret, isNot(old));
      expect(calls, 1);
      expect(await p.pair(PairRequest(secret: old, name: 'Mac')), isNull);
      expect((await Settings.load()).companionSecret, p.secret);
    },
  );
}
