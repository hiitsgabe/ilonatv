import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv/locale.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/settings_import.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    deviceLocale = () => 'en_CA';
    dir = Directory.systemTemp.createTempSync('import');
    file = File('${dir.path}/import/settings.json');
  });
  tearDown(() {
    deviceLocale = () => Platform.localeName;
    dir.deleteSync(recursive: true);
  });

  void put(Object json) {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(json is String ? json : jsonEncode(json));
  }

  test('no file: nothing changes', () async {
    await importSettings(file);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('valid keys are written with their types, then the file goes', () async {
    put({
      'setupDone': true,
      'fireTvMode': true,
      'assistantColor': 4283403263,
      'weatherLat': -23.5,
      'weatherLon': 46,
      'language': 'pt',
      'tmdbKey': 'k',
      'stremioAuthKey': 'a',
      'tiles': jsonEncode([
        {'package': 'com.example.tv', 'icon': 'tv'},
      ]),
      'youtubeAccounts': jsonEncode([
        {'refreshToken': 'r', 'name': 'n'},
      ]),
      'companionDevices': jsonEncode({'tok': 'Phone'}),
      'homeRows': jsonEncode([
        {'key': 'games', 'on': false},
      ]),
      'hiddenApps': jsonEncode(['a.b']),
      'rowProviders': jsonEncode({'trendingMovies': 8}),
    });
    await importSettings(file);
    final p = await SharedPreferences.getInstance();
    expect(p.getBool('setupDone'), isTrue);
    expect(p.getBool('fireTvMode'), isTrue);
    expect(p.getInt('assistantColor'), 4283403263);
    expect(p.getDouble('weatherLat'), -23.5);
    expect(p.getDouble('weatherLon'), 46.0);
    expect(p.getString('language'), 'pt');
    expect(p.getString('tmdbKey'), 'k');
    expect(p.getString('stremioAuthKey'), 'a');
    expect(jsonDecode(p.getString('tiles')!), [
      {'package': 'com.example.tv', 'icon': 'tv'},
    ]);
    expect(jsonDecode(p.getString('companionDevices')!), {'tok': 'Phone'});
    expect(file.existsSync(), isFalse);
  });

  test('unknown keys, wrong types and companionSecret are skipped', () async {
    SharedPreferences.setMockInitialValues({
      'companionSecret': 'mine',
      'tmdbKey': 'old',
    });
    put({
      'companionSecret': 'theirs',
      'nope': 'x',
      'tmdbKey': 3,
      'fireTvMode': 'yes',
      'assistantColor': 1.5,
      'tiles': jsonEncode({'package': 'x'}),
      'youtubeAccounts': jsonEncode([
        {'name': 'no token'},
      ]),
      'homeRows': '[not json',
      'recentSearches': jsonEncode([1]),
      'geminiKey': 'g',
    });
    await importSettings(file);
    final p = await SharedPreferences.getInstance();
    expect(p.getString('companionSecret'), 'mine');
    expect(p.getString('tmdbKey'), 'old');
    expect(p.getString('geminiKey'), 'g');
    expect(
      p.getKeys(),
      unorderedEquals(['companionSecret', 'tmdbKey', 'geminiKey']),
    );
    expect(file.existsSync(), isFalse);
  });

  test('malformed JSON imports nothing and the file goes', () async {
    put('{"tmdbKey": "k"');
    await importSettings(file);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('a JSON that is not an object imports nothing', () async {
    put(['tmdbKey', 'k']);
    await importSettings(file);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('every key save() writes is importable, but companionSecret', () async {
    await (await Settings.load()).save();
    final saved = (await SharedPreferences.getInstance()).getKeys();
    expect(importKeys, containsAll(saved.difference({'companionSecret'})));
    expect(importKeys, isNot(contains('companionSecret')));
  });

  test('load after an import runs the migrations of the older build', () async {
    put({
      'tiles': jsonEncode([
        {'package': 'elimor:apps', 'icon': 'apps'},
        {'package': 'elimor:settings', 'icon': 'settings'},
        {'package': 'com.example.tv', 'icon': 'netflix'},
      ]),
      'settingsTileDropped': true,
      'homeRows': jsonEncode([
        {'key': 'matchesBrazil', 'on': false},
      ]),
    });
    await importSettings(file);
    final s = await Settings.load();
    expect(s.tiles.map((t) => t.toJson()), [
      {'package': 'ilonatv:apps', 'icon': 'apps'},
      {'package': 'ilonatv:settings', 'icon': 'settings'},
      {'package': 'com.example.tv', 'icon': 'app'},
    ]);
    expect(s.homeRows.firstWhere((r) => r.key == 'games').on, isFalse);
    expect(s.setupDone, isTrue);
    expect(s.companionSecret, hasLength(32));
  });
}
