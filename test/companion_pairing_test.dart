import 'dart:math';

import 'package:ilonatv/companion/pairing.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  var clock = DateTime(2026);
  setUp(() {
    clock = DateTime(2026);
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> miss(Pairing p, [int n = 5]) async {
    final bad = p.code == '000000' ? '000001' : '000000';
    for (var i = 0; i < n; i++) {
      await p.pair(PairRequest(code: bad, name: 'X'));
    }
  }

  Future<(Settings, Pairing)> make() async {
    final s = await Settings.load();
    return (s, Pairing(s, random: Random(1), now: () => clock)..offerCode());
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

  test('a secret pairs once, and the QR shows the next', () async {
    final (s, p) = await make();
    final old = s.companionSecret;
    var calls = 0;
    p.addListener(() => calls++);
    expect(await p.pair(PairRequest(secret: old, name: 'Mac')), isNotNull);
    expect(p.secret, isNot(old));
    expect(p.secret, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(calls, 1);
    expect((await Settings.load()).companionSecret, p.secret);
    expect(await p.pair(PairRequest(secret: old, name: 'Mac')), isNull);
    expect(s.companionDevices, hasLength(1));
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

  test('remove renews the secret', () async {
    final (s, p) = await make();
    final token = (await p.pair(PairRequest(code: p.code, name: 'A')))!;
    final old = s.companionSecret;
    await p.remove(token);
    expect(p.secret, isNot(old));
    expect((await Settings.load()).companionSecret, p.secret);
    expect(await p.pair(PairRequest(secret: old, name: 'A')), isNull);
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

  test('a code does not pair unless offered', () async {
    final (_, p) = await make();
    p.withdrawCode();
    expect(p.codeOffered, isFalse);
    final code = p.code;
    await miss(p, 10);
    expect(await p.pair(PairRequest(code: code, name: 'A')), isNull);
    p.offerCode();
    expect(await p.pair(PairRequest(code: code, name: 'A')), isNotNull);
  });

  test('misses while not offered do not count', () async {
    final (_, p) = await make();
    final code = p.code;
    p.withdrawCode();
    await miss(p, 10);
    p.offerCode();
    expect(p.code, code);
    await miss(p, 4);
    expect(p.code, code);
  });

  test(
    'after a replacement, codes are refused for 10 s, then accepted',
    () async {
      final (_, p) = await make();
      await miss(p);
      final fresh = p.code;
      clock = clock.add(const Duration(seconds: 9));
      expect(await p.pair(PairRequest(code: fresh, name: 'A')), isNull);
      expect(p.code, fresh);
      clock = clock.add(const Duration(seconds: 1));
      expect(await p.pair(PairRequest(code: fresh, name: 'A')), isNotNull);
    },
  );

  test('the wait doubles per replacement and stops at an hour', () async {
    final (_, p) = await make();
    var wait = 10;
    for (var i = 0; i < 12; i++) {
      await miss(p);
      final expected = wait > 3600 ? 3600 : wait;
      clock = clock.add(Duration(seconds: expected - 1));
      final code = p.code;
      await miss(p);
      expect(p.code, code, reason: 'refused inside the wait, round $i');
      clock = clock.add(const Duration(seconds: 1));
      wait *= 2;
    }
  });

  test('an empty secret never pairs', () async {
    final (s, p) = await make();
    s.companionSecret = '';
    expect(await p.pair(PairRequest(secret: '', name: 'Mac')), isNull);
    expect(s.companionDevices, isEmpty);
  });
}
