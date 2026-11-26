import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/youtube_tv.dart';
import 'settings.dart';

/// Each check returns the value to store, or throws for a wrong type.
typedef _Check = Object Function(Object? value);

Object _bool(Object? v) => v as bool;
Object _int(Object? v) => v as int;
Object _double(Object? v) => (v as num).toDouble();
Object _string(Object? v) => v as String;

/// A string holding JSON that [shape] reads without throwing.
_Check _json(void Function(Object? decoded) shape) => (v) {
  shape(jsonDecode(v as String));
  return v;
};

final _stringList = _json((d) => (d as List).cast<String>().toList());
final _stringMap = _json((d) => Map<String, String>.from(d as Map));

/// The prefs [Settings] owns, by key. Never `companionSecret` or
/// `companionDevices`: the TV keeps its own, and phones pair again with the QR,
/// so a phone paired with another TV cannot control this one.
final Map<String, _Check> _keys = {
  for (final k in [
    'setupDone',
    'settingsTileDropped',
    'fireTvMode',
    'doublePowerFix',
    'stremioAutoPlay',
    'alexaBounce',
    'fahrenheit',
    'gamesBySport',
  ])
    k: _bool,
  'assistantColor': _int,
  'weatherLat': _double,
  'weatherLon': _double,
  for (final k in [
    'language',
    'country',
    'tmdbKey',
    'geminiKey',
    'stremioAuthKey',
    'stremioEmail',
    'weatherCity',
    'movieProvider',
    'seriesProvider',
    'youtubeProvider',
    'youtubeDeviceId',
  ])
    k: _string,
  'tiles': _json(
    (d) => [for (final t in d as List) AppTile.fromJson(t as Map)],
  ),
  'youtubeAccounts': _json(
    (d) => [for (final a in d as List) YtAccount.fromJson(a as Map)],
  ),
  'sports': _json(
    (d) => [for (final f in d as List) SportsFollow.fromJson(f as Map)],
  ),
  'homeRows': _json((d) {
    for (final r in d as List) {
      (r as Map)['key'] as String;
      r['on'] as bool;
    }
  }),
  'rowProviders': _json(
    (d) => (d as Map).forEach((k, v) => (k as String, v as num)),
  ),
  'rowGenres': _stringMap,
  'serviceApps': _stringMap,
  'hiddenApps': _stringList,
  'recentSearches': _stringList,
};

@visibleForTesting
Iterable<String> get importKeys => _keys.keys;

/// Writes the prefs in [file] (a JSON object of pref key to value, put there
/// over adb through PairingProvider.kt) and deletes it. Runs before
/// [Settings.load], so the load's migrations apply to what came in. Keys not
/// in [_keys] or of the wrong type are skipped; an unreadable file, or one
/// over 1 MB, imports nothing. Logs keys, never values: they hold account tokens.
Future<void> importSettings(File file) async {
  if (!file.existsSync()) return;
  try {
    // A huge file must never keep the launcher from starting.
    if (await file.length() > 1 << 20) {
      debugPrint('settings import: file over 1 MB, nothing imported');
      return;
    }
    final json = jsonDecode(await file.readAsString());
    if (json is! Map<String, dynamic>) throw const FormatException();
    final prefs = await SharedPreferences.getInstance();
    var imported = 0;
    for (final MapEntry(:key, :value) in json.entries) {
      Object? ok;
      try {
        ok = _keys[key]?.call(value);
      } catch (_) {}
      if (ok == null) {
        debugPrint('settings import: skipped $key');
        continue;
      }
      await switch (ok) {
        bool v => prefs.setBool(key, v),
        int v => prefs.setInt(key, v),
        double v => prefs.setDouble(key, v),
        _ => prefs.setString(key, ok as String),
      };
      imported++;
    }
    debugPrint('settings import: $imported keys');
  } catch (_) {
    // Not the error itself: a FormatException quotes the file.
    debugPrint('settings import: unreadable file, nothing imported');
  } finally {
    try {
      await file.delete();
    } catch (_) {
      debugPrint('settings import: could not delete the file');
    }
  }
}
