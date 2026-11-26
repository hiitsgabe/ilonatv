import 'dart:async';
import 'dart:io';

import 'package:elimor/data/weather.dart';
import 'package:elimor/net.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// The fixture's forecast, as the source keeps it.
const _shown = {'temp': 4.2, 'feelsLike': 1.1, 'code': 3};

/// The fixture's forecast with another temperature.
Map<String, dynamic> _forecast(double temp) {
  final json = fixture('open_meteo_forecast.json');
  (json['current'] as Map)['temperature_2m'] = temp;
  return json;
}

/// The network: notes every request and answers it with [reply], which a test
/// swaps for one that throws to play an error.
class _Net {
  final uris = <Uri>[];
  Map<String, dynamic> Function() reply = () =>
      fixture('open_meteo_forecast.json');

  Future<Map<String, dynamic>> call(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    uris.add(uri);
    return reply();
  }
}

void main() {
  test('parseForecast reads the current block', () {
    final w = parseForecast(fixture('open_meteo_forecast.json'));
    expect([w.temp, w.feelsLike, w.code], [4.2, 1.1, 3]);

    // Whole numbers come out as doubles too.
    final whole = parseForecast({
      'current': {
        'temperature_2m': 4,
        'apparent_temperature': -1,
        'weather_code': 3,
      },
    });
    expect([whole.temp, whole.feelsLike, whole.code], [4.0, -1.0, 3]);
  });

  test('weatherIcon maps WMO codes', () {
    List<int> range(int from, int to) => [for (var c = from; c <= to; c++) c];
    final listed = <IconData, List<int>>{
      Icons.wb_sunny: [0],
      Icons.cloud_queue: [1, 2],
      Icons.blur_on: [45, 48],
      Icons.umbrella: [...range(51, 67), ...range(80, 82)],
      Icons.ac_unit: [...range(71, 77), 85, 86],
      Icons.flash_on: range(95, 99),
    };
    final byCode = {
      for (final MapEntry(:key, :value) in listed.entries)
        for (final code in value) code: key,
    };
    // Every code around the table, edges included: what is not listed (3,
    // overcast, among it) is the cloud.
    for (final code in [...range(-2, 101), 999]) {
      expect(
        weatherIcon(code),
        byCode[code] ?? Icons.cloud,
        reason: 'WMO $code',
      );
    }
  });

  test('parseGeocoding keeps name, region, country, coords', () {
    final p = parseGeocoding(fixture('open_meteo_geocoding.json'));
    expect(p.length, 2);
    expect(
      [
        p.first.name,
        p.first.region,
        p.first.country,
        p.first.lat,
        p.first.lon,
        p.first.countryCode,
      ],
      ['Paris', 'Île-de-France Region', 'France', 48.85341, 2.3488, 'FR'],
    );
    expect(
      [p.last.region, p.last.country, p.last.countryCode],
      ['Texas', 'United States', 'US'],
    );
  });

  test('parseGeocoding takes a place with no region, and no results', () {
    final p = parseGeocoding({
      'results': [
        {
          'name': 'Singapore',
          'country': 'Singapore',
          'latitude': 1,
          'longitude': 103.85,
        },
      ],
    });
    expect(
      [
        p.single.name,
        p.single.region,
        p.single.country,
        p.single.lat,
        p.single.countryCode,
      ],
      ['Singapore', '', 'Singapore', 1.0, ''],
    );
    // A search that finds nothing has no `results` key at all.
    expect(parseGeocoding({'generationtime_ms': 0.5}), isEmpty);
  });

  test('the URIs are the ones Open-Meteo documents', () {
    expect(
      forecastUri(48.85, 2.35).toString(),
      'https://api.open-meteo.com/v1/forecast?latitude=48.85&longitude=2.35'
      '&current=temperature_2m,apparent_temperature,weather_code'
      '&timezone=auto',
    );
    expect(
      forecastUri(48.85, 2.35, fahrenheit: true).toString(),
      'https://api.open-meteo.com/v1/forecast?latitude=48.85&longitude=2.35'
      '&current=temperature_2m,apparent_temperature,weather_code'
      '&timezone=auto&temperature_unit=fahrenheit',
    );
    expect(
      geocodingUri('São Paulo', 'pt').toString(),
      'https://geocoding-api.open-meteo.com/v1/search?name=S%C3%A3o%20Paulo'
      '&count=5&language=pt&format=json',
    );
  });

  group('WeatherSource', () {
    late Directory dir;
    late Settings settings;
    late Store store;
    late _Net net;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = (await Settings.load())
        ..weatherCity = 'Paris'
        ..weatherLat = 48.85
        ..weatherLon = 2.35
        ..fahrenheit = false;
      dir = await Directory.systemTemp.createTemp('elimor');
      store = Store(dir);
      net = _Net();
    });
    tearDown(() => dir.delete(recursive: true));

    WeatherSource source([Store? on]) =>
        WeatherSource(settings, on ?? store, fetch: net.call);

    test('uses the cache when fresh and the network when stale', () async {
      // 1) No cache: refresh() asks, shows it and writes the cache.
      final first = source();
      await first.refresh();
      expect(first.current!.toJson(), _shown);
      expect(net.uris, [forecastUri(48.85, 2.35)]);
      expect(await store.read('weather'), {
        'weather': _shown,
        'lat': 48.85,
        'lon': 2.35,
        'fahrenheit': false,
      });

      // 2) The app restarts: the cache is shown at once and is not asked again.
      final second = source();
      expect(second.current, isNull);
      await second.loadCache();
      expect(second.current!.toJson(), _shown);
      await second.refresh();
      expect(net.uris, hasLength(1));

      // 3) force asks anyway.
      await second.refresh(force: true);
      expect(net.uris, hasLength(2));

      // 4) A failing network leaves what is shown.
      net.reply = () => throw const SocketException('offline');
      await second.refresh(force: true);
      expect(net.uris, hasLength(3));
      expect(second.current!.toJson(), _shown);
    });

    test(
      'a cache stands for 30 minutes; older, or from the future, goes',
      () async {
        final s = source();
        await s.refresh();
        final file = File('${dir.path}/cache/weather.json');
        void age(Duration d) =>
            file.setLastModifiedSync(DateTime.now().subtract(d));

        age(const Duration(minutes: 29));
        await s.refresh();
        expect(net.uris, hasLength(1), reason: '29 minutes old');

        age(const Duration(minutes: 31));
        await s.refresh();
        expect(net.uris, hasLength(2), reason: '31 minutes old');
        // The same weather again still made the cache young.
        expect(
          DateTime.now().difference((await store.writtenAt('weather'))!),
          lessThan(const Duration(minutes: 1)),
        );

        age(const Duration(minutes: -5));
        await s.refresh();
        expect(net.uris, hasLength(3), reason: 'written in the future');
      },
    );

    test('a cache for another city is shown, then replaced', () async {
      await source().refresh();
      settings
        ..weatherLat = 38.72
        ..weatherLon = -9.14;

      final s = source();
      await s.loadCache();
      expect(s.current!.toJson(), _shown);

      net.reply = () => _forecast(15);
      await s.refresh();
      expect(net.uris.last, forecastUri(38.72, -9.14));
      expect(s.current!.temp, 15.0);
      expect(await store.read('weather'), {
        'weather': {'temp': 15.0, 'feelsLike': 1.1, 'code': 3},
        'lat': 38.72,
        'lon': -9.14,
        'fahrenheit': false,
      });

      await s.refresh();
      expect(net.uris, hasLength(2), reason: 'fresh for the new city');
    });

    test('the unit is asked for and is part of the cache', () async {
      final s = source();
      await s.refresh();
      settings.fahrenheit = true;
      net.reply = () => _forecast(40);
      await s.refresh();
      expect(net.uris, [
        forecastUri(48.85, 2.35),
        forecastUri(48.85, 2.35, fahrenheit: true),
      ]);
      expect(s.current!.temp, 40.0);
      await s.refresh();
      expect(net.uris, hasLength(2), reason: 'fresh in this unit');
      // A cache from before the unit was kept reads as Celsius.
      settings.fahrenheit = false;
      await store.write('weather', {
        'weather': _shown,
        'lat': 48.85,
        'lon': 2.35,
      });
      await s.refresh();
      expect(net.uris, hasLength(2));
    });

    test('no city: nothing asked, nothing shown', () async {
      final s = source();
      await s.refresh();
      expect(s.current, isNotNull);
      settings.weatherCity = '';
      var heard = 0;
      s.addListener(() => heard++);
      await s.refresh(force: true);
      expect([s.current, heard, net.uris.length], [null, 1, 1]);
      final again = source();
      await again.loadCache();
      await again.refresh();
      expect([again.current, net.uris.length], [null, 1]);
    });

    test('whatever goes wrong, what is shown stays', () async {
      final s = source();
      net.reply = () => throw const SocketException('offline');
      await s.refresh();
      expect(s.current, isNull);
      expect(await store.read('weather'), isNull);

      net.reply = () => fixture('open_meteo_forecast.json');
      await s.refresh();
      expect(s.current!.toJson(), _shown);

      final failures = <Map<String, dynamic> Function()>[
        () => throw const SocketException('offline'),
        () => throw TimeoutException('slow'),
        () => throw const HttpStatusException(500, 'oops'),
        () => throw const FormatException('html'),
        () => throw const HandshakeException('tls'),
        () => {'error': true, 'reason': 'not a forecast'},
        () => {
          'current': {'temperature_2m': null},
        },
      ];
      for (final failure in failures) {
        net.reply = failure;
        await s.refresh(force: true);
        expect(s.current!.toJson(), _shown);
      }
      expect(await store.read('weather'), isNotNull);
    });

    test('listeners hear a new value, not a repeat', () async {
      final s = source();
      var heard = 0;
      s.addListener(() => heard++);

      await s.refresh();
      expect(heard, 1);
      await s.refresh(force: true);
      expect(heard, 1);

      net.reply = () => _forecast(5);
      await s.refresh(force: true);
      expect(heard, 2);
      expect(s.current!.temp, 5.0);
    });

    test('an answer for a city that was replaced is dropped', () async {
      // What picking another city does, one coordinate at a time.
      for (final change in <void Function()>[
        () => settings.weatherLat = 38.72,
        () => settings.weatherLon = -9.14,
        () => settings.fahrenheit = true,
      ]) {
        final gate = Completer<void>();
        final s = WeatherSource(
          settings,
          store,
          fetch: (uri, {headers = const {}}) async {
            await gate.future;
            return fixture('open_meteo_forecast.json');
          },
        );
        var heard = 0;
        s.addListener(() => heard++);

        final pending = s.refresh(force: true);
        change();
        gate.complete();
        await pending;
        settings
          ..weatherLat = 48.85
          ..weatherLon = 2.35
          ..fahrenheit = false;

        expect([s.current, heard], [null, 0]);
        expect(await store.read('weather'), isNull);
      }
    });

    test('a cache that will not write does not fail a good fetch', () async {
      final s = source(FullDiskStore(dir));

      await s.refresh();
      expect(s.current!.toJson(), _shown);
      expect(await store.read('weather'), isNull);
    });

    test('a cache in the wrong shape is skipped, then replaced', () async {
      for (final bad in <Object?>[
        'x',
        null,
        {'temp': 'warm'},
        <Object?>[],
      ]) {
        await store.write('weather', {
          'weather': bad,
          'lat': 48.85,
          'lon': 2.35,
        });
        final s = source();
        await s.loadCache();
        expect(s.current, isNull, reason: '$bad');

        // It reads as young, but with nothing to show it is not a cache.
        await s.refresh();
        expect(s.current!.toJson(), _shown, reason: '$bad');
      }

      // A cache written by hand with whole numbers loads.
      await store.write('weather', {
        'weather': {'temp': 4, 'feelsLike': 1, 'code': 3},
        'lat': 48.85,
        'lon': 2.35,
      });
      final s = source();
      await s.loadCache();
      expect([s.current!.temp, s.current!.feelsLike], [4.0, 1.0]);
    });

    test('search asks in the UI language and gives up quietly', () async {
      net.reply = () => fixture('open_meteo_geocoding.json');
      final s = source();
      expect((await s.search('Paris')).map((p) => p.region), [
        'Île-de-France Region',
        'Texas',
      ]);
      expect(net.uris.last, geocodingUri('Paris', 'en'));

      settings.language = 'pt';
      await s.search('São Paulo');
      expect(net.uris.last, geocodingUri('São Paulo', 'pt'));

      settings.language = 'xx';
      await s.search('Lisboa');
      expect(net.uris.last, geocodingUri('Lisboa', 'en'));

      net.reply = () => throw const SocketException('offline');
      expect(await s.search('Paris'), isEmpty);
      net.reply = () => {'results': 'nothing'};
      expect(await s.search('Paris'), isEmpty);
      expect(s.current, isNull);
    });

    test(
      'start arms one 30 minute timer whose tick refetches; stop cancels',
      () async {
        final zone = FakeTimerZone();
        final s = WeatherSource(settings, MemStore(), fetch: net.call);

        await zone.run(() async {
          s.stop(); // never started: nothing to cancel
          s.start();
          await pumpEventQueue();
          expect(net.uris, hasLength(1), reason: 'start refreshes at once');
          s.start();
          await pumpEventQueue();
          expect(net.uris, hasLength(1), reason: 'the cache is fresh');
          expect(zone.timers.map((t) => t.period), [
            const Duration(minutes: 30),
          ]);

          // The tick comes when the cache is just under 30 minutes old: it must
          // ask anyway.
          net.reply = () => _forecast(5);
          zone.timers.single.fire();
          await pumpEventQueue();
          expect(net.uris, hasLength(2));
          expect(s.current!.temp, 5.0);

          s.stop();
          expect(zone.timers.single.isActive, isFalse);
          s.start(); // a resume after a pause arms a new one
          await pumpEventQueue();
          expect(zone.timers, hasLength(2));
          expect(zone.timers.where((t) => t.isActive), hasLength(1));
          s.stop();
          expect(zone.timers.where((t) => t.isActive), isEmpty);
        });
      },
    );
  });
}
