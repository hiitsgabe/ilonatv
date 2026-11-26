import 'dart:math';

import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/foundation.dart';

import '../settings.dart';

const _maxCodeFails = 5;

class Pairing extends ChangeNotifier {
  Pairing(this.settings, {Random? random, DateTime Function()? now})
    : _random = random ?? Random.secure(),
      _now = now ?? DateTime.now {
    _code = _newCode();
  }

  final Settings settings;
  final Random _random;
  final DateTime Function() _now;
  var _offered = false;
  var _replacements = 0;
  DateTime? _blockedUntil;
  late String _code;
  var _fails = 0;

  String get code => _code;
  String get secret => settings.companionSecret;

  bool get codeOffered => _offered;

  void offerCode() => _offered = true;

  void withdrawCode() => _offered = false;

  String _newCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

  void _replaceCode() {
    _code = _newCode();
    _fails = 0;
  }

  Future<String?> pair(PairRequest r) async {
    final s = r.secret;
    final bySecret =
        s != null && s.isNotEmpty && secret.isNotEmpty && _same(s, secret);
    var byCode = false;
    final c = r.code;
    final blocked = _blockedUntil != null && _now().isBefore(_blockedUntil!);
    if (!bySecret && c != null && _offered && !blocked) {
      byCode = _same(c, _code);
      if (!byCode && ++_fails >= _maxCodeFails) {
        _replaceCode();
        final wait = Duration(
          seconds: min(10 * (1 << min(_replacements, 20)), 3600),
        );
        _replacements++;
        _blockedUntil = _now().add(wait);
        notifyListeners();
      }
    }
    if (!bySecret && !byCode) return null;
    if (byCode) {
      _replaceCode();
      _replacements = 0;
      _blockedUntil = null;
    }
    final token = randomHex(_random);
    settings.companionDevices[token] = r.name;
    await settings.save();
    notifyListeners();
    return token;
  }

  bool isValid(String token) {
    var ok = false;
    for (final t in settings.companionDevices.keys) {
      if (_same(t, token)) ok = true;
    }
    return ok;
  }

  Future<void> remove(String token) async {
    settings.companionDevices.remove(token);
    await settings.save();
    notifyListeners();
  }

  Future<void> renewSecret() async {
    settings.companionSecret = randomHex();
    await settings.save();
    notifyListeners();
  }
}

bool _same(String a, String b) {
  var diff = a.length ^ b.length;
  for (var i = 0; i < a.length && i < b.length; i++) {
    diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
  }
  return diff == 0;
}
