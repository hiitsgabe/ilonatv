import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop/host.dart';
import 'desktop/mdns.dart';
import 'version.dart';

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

  // The service name is "Ilona TV on <model>"; the model is a detail for the list.
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
  if (isDesktop) return desktopName();
  try {
    return await Tvs._channel.invokeMethod<String>('deviceName') ?? 'Phone';
  } on PlatformException {
    return 'Phone';
  } on MissingPluginException {
    return 'Phone';
  }
}

/// The installed versionName, like 0.6.1; null when the platform can't say.
Future<String?> appVersion() async {
  if (isDesktop) return kVersion;
  try {
    return await Tvs._channel.invokeMethod<String>('appVersion');
  } on PlatformException {
    return null;
  } on MissingPluginException {
    return null;
  }
}

/// The app's cache directory, where its update downloads.
Future<String> cacheDir() async =>
    (await Tvs._channel.invokeMethod<String>('cacheDir'))!;

/// Whether the person allowed the companion to install apps.
Future<bool> canInstall() async =>
    await Tvs._channel.invokeMethod<bool>('canInstall') ?? false;

/// Opens the setting that allows the companion to install apps.
Future<void> allowInstalls() =>
    Tvs._channel.invokeMethod<void>('allowInstalls');

/// Installs the APK at [path] over the companion after the system's confirm.
/// An update that went through ends this process, so the answer is only ever
/// why it did not (declined, a bad APK), or null.
Future<String?> installApk(String path) =>
    Tvs._channel.invokeMethod<String>('installApk', {'path': path});

Future<bool> openUrl(String url) async {
  if (isDesktop) return openUrlOnDesktop(url);
  try {
    return await Tvs._channel.invokeMethod<bool>('openUrl', url) ?? false;
  } on PlatformException {
    return false;
  } on MissingPluginException {
    return false;
  }
}

/// Whether the phone's volume rocker drives the TV ([Tvs.onVolumeKey]) rather
/// than the phone.
Future<void> hardwareVolume(bool on) async {
  if (isDesktop) return;
  try {
    await Tvs._channel.invokeMethod<void>('volumeKeys', on);
  } on PlatformException {
    return;
  } on MissingPluginException {
    return;
  }
}

/// Finds TVs where the host channel's NSD can't: the desktop app.
abstract interface class Discovery {
  void start(
    void Function(String name, String host, int port) found,
    void Function(String name) lost,
  );
  void stop();
}

class Tvs extends ChangeNotifier {
  Tvs({Discovery? discovery})
    : _discovery = discovery ?? (isDesktop ? MdnsDiscovery() : null) {
    _channel.setMethodCallHandler(_fromHost);
  }

  /// Null on Android, where MainActivity's NSD answers on the channel.
  final Discovery? _discovery;

  static const _key = 'tvs';
  static const _channel = MethodChannel('tv.ilona.companion/host');

  /// The rocker pressed while [hardwareVolume] is on: true for up.
  void Function(bool up)? onVolumeKey;

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

  bool _wanted = false;
  bool _running = false;
  int _held = 0;

  void startDiscovery() {
    _wanted = true;
    _apply();
  }

  void stopDiscovery() {
    _wanted = false;
    _apply();
  }

  /// Pages that have no use for found TVs (the remote, the installer, a hidden app) hold discovery off,
  /// each with one hold() and one release(); a counter, since one may replace another.
  void hold() {
    _held++;
    _apply();
  }

  void release() {
    _held--;
    _apply();
  }

  void _apply() {
    final on = _wanted && _held == 0;
    if (on == _running) return;
    _running = on;
    final d = _discovery;
    if (on) {
      d == null
          ? _channel.invokeMethod<void>('discoverStart')
          : d.start(_found, _lost);
      return;
    }
    d == null ? _channel.invokeMethod<void>('discoverStop') : d.stop();
    _seen.clear();
    _hostByService.clear();
    for (final t in _paired.values) {
      t.found = false;
    }
    // A hold() can come from a page's initState, mid-build, where listeners may not rebuild yet.
    scheduleMicrotask(notifyListeners);
  }

  Future<void> _fromHost(MethodCall call) async {
    final a = call.arguments as Map;
    if (call.method == 'volumeKey') return onVolumeKey?.call(a['up'] == true);
    final name = a['name'] as String;
    if (call.method == 'found') {
      _found(name, a['host'] as String, a['port'] as int);
    } else if (call.method == 'lost') {
      _lost(name);
    }
  }

  void _found(String name, String host, int port) {
    if (!_running) return;
    _seen[host] = Tv(host: host, port: port, name: name, found: true);
    _hostByService[name] = host;
    final p = _paired[host];
    if (p != null) {
      p.port = port;
      p.found = true;
    }
    notifyListeners();
  }

  void _lost(String name) {
    if (!_running) return;
    final host = _hostByService.remove(name);
    if (host == null) return;
    _seen.remove(host);
    _paired[host]?.found = false;
    notifyListeners();
  }
}
