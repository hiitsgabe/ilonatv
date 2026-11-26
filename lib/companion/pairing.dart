import 'dart:math';

import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/foundation.dart';

import '../settings.dart';

const _maxCodeFails = 5;

class Pairing extends ChangeNotifier {
  Pairing(this.settings, {Random? random})
    : _random = random ?? Random.secure() {
    _code = _newCode();
  }

  final Settings settings;
  final Random _random;
  late String _code;
  var _fails = 0;

  String get code => _code;
  String get secret => settings.companionSecret;

  String _newCode() => _random.nextInt(1000000).toString().padLeft(6, '0');

  void _replaceCode() {
    _code = _newCode();
    _fails = 0;
  }

  Future<String?> pair(PairRequest r) async {
    final bySecret = r.secret != null && _same(r.secret!, secret);
    var byCode = false;
    if (!bySecret && r.code != null) {
      byCode = _same(r.code!, _code);
      if (!byCode && ++_fails >= _maxCodeFails) {
        _replaceCode();
        notifyListeners();
      }
    }
    if (!bySecret && !byCode) return null;
    if (byCode) {
      _replaceCode();
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
