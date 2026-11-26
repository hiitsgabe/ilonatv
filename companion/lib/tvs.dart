import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Tv {
  Tv({
    required this.host,
    required this.port,
    required this.name,
    this.token,
    this.found = false,
  });

  String host;
  int port;
  String name;
  String? token;
  bool found;

  // The service name is "IlonaTv on <model>"; the model is a detail for the list.
  String get label {
    final i = name.lastIndexOf(' on ');
    return i > 0 ? name.substring(0, i) : name;
  }

  Map<String, Object?> toJson() => {
    'host': host,
    'port': port,
    'name': name,
    'token': token,
  };
}

Future<String> deviceName() async {
  try {
    return await Tvs._channel.invokeMethod<String>('deviceName') ?? 'Phone';
  } on PlatformException {
    return 'Phone';
  } on MissingPluginException {
    return 'Phone';
  }
}

Future<bool> openUrl(String url) async {
  try {
    return await Tvs._channel.invokeMethod<bool>('openUrl', url) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

class Tvs extends ChangeNotifier {
  static const _key = 'tvs';
  static const _channel = MethodChannel('tv.ilona.companion/host');

  final _paired = <String, Tv>{};
  final _seen = <String, Tv>{};
  final _hostByService = <String, String>{};

  List<Tv> get all {
    final unpaired = _seen.values.where((t) => !_paired.containsKey(t.host));
    return [..._paired.values, ...unpaired];
  }

  Future<void> load() async {
    final raw = (await SharedPreferences.getInstance()).getString(_key);
    _paired.clear();
    if (raw != null) {
      try {
        for (final e in jsonDecode(raw) as List) {
          try {
            final m = e as Map<String, dynamic>;
            final tv = Tv(
              host: m['host'] as String,
              port: m['port'] as int,
              name: m['name'] as String,
              token: m['token'] as String?,
              found: _seen.containsKey(m['host']),
            );
            _paired[tv.host] = tv;
          } on TypeError {
            continue;
          }
        }
      } on FormatException {
        _paired.clear();
      } on TypeError {
        _paired.clear();
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(_paired.values.map((t) => t.toJson()).toList()),
    );
  }

  Future<void> savePaired(Tv tv, String token) async {
    _paired[tv.host] = Tv(
      host: tv.host,
      port: tv.port,
      name: tv.name,
      token: token,
      found: _seen.containsKey(tv.host),
    );
    await _save();
    notifyListeners();
  }

  Future<void> forget(String host) async {
    _paired.remove(host);
    await _save();
    notifyListeners();
  }

  void startDiscovery() {
    _channel.setMethodCallHandler(_fromHost);
    _channel.invokeMethod<void>('discoverStart');
  }

  void stopDiscovery() {
    _channel.setMethodCallHandler(null);
    _channel.invokeMethod<void>('discoverStop');
    _seen.clear();
    _hostByService.clear();
    for (final t in _paired.values) {
      t.found = false;
    }
    notifyListeners();
  }

  Future<void> _fromHost(MethodCall call) async {
    final a = call.arguments as Map;
    final name = a['name'] as String;
    if (call.method == 'found') {
      final tv = Tv(
        host: a['host'] as String,
        port: a['port'] as int,
        name: name,
        found: true,
      );
      _seen[tv.host] = tv;
      _hostByService[name] = tv.host;
      final p = _paired[tv.host];
      if (p != null) {
        p.port = tv.port;
        p.found = true;
      }
    } else if (call.method == 'lost') {
      final host = _hostByService.remove(name);
      if (host == null) return;
      _seen.remove(host);
      _paired[host]?.found = false;
    } else {
      return;
    }
    notifyListeners();
  }
}
