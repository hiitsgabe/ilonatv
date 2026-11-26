import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../net.dart';
import '../settings.dart';
import '../store.dart';

/// How old the cached forecast may be, and how often the open app asks again.
const _every = Duration(minutes: 30);

const _cache = 'weather';

class Weather {
  final double temp;
  final double feelsLike;

  /// WMO weather code, see [weatherIcon].
  final int code;
  const Weather(this.temp, this.feelsLike, this.code);

  Map<String, dynamic> toJson() => {
    'temp': temp,
    'feelsLike': feelsLike,
    'code': code,
  };

  factory Weather.fromJson(Map json) => Weather(
    (json['temp'] as num).toDouble(),
    (json['feelsLike'] as num).toDouble(),
    (json['code'] as num).toInt(),
  );
}

/// Reads the `current` block of Open-Meteo's forecast.
Weather parseForecast(Map<String, dynamic> json) {
  final current = json['current'] as Map;
  return Weather(
    (current['temperature_2m'] as num).toDouble(),
    (current['apparent_temperature'] as num).toDouble(),
    (current['weather_code'] as num).toInt(),
  );
}

IconData weatherIcon(int code) => switch (code) {
  0 => Icons.wb_sunny,
  1 || 2 => Icons.cloud_queue,
  45 || 48 => Icons.blur_on,
  >= 51 && <= 67 || >= 80 && <= 82 => Icons.umbrella,
  >= 71 && <= 77 || 85 || 86 => Icons.ac_unit,
  >= 95 && <= 99 => Icons.flash_on,
  _ => Icons.cloud, // 3 (overcast) and every code not listed
};

/// One result of the city search. [region] and [countryCode] (ISO 3166-1
/// alpha-2) are empty when Open-Meteo gives none.
class Place {
  final String name;
  final String region;
  final String country;
  final double lat;
  final double lon;
  final String countryCode;
  const Place(
    this.name,
    this.region,
    this.country,
    this.lat,
    this.lon, [
    this.countryCode = '',
  ]);
}

/// Reads Open-Meteo's geocoding answer; a search that finds nothing has no
/// `results`.
List<Place> parseGeocoding(Map<String, dynamic> json) => [
  for (final r in json['results'] as List? ?? const [])
    Place(
      r['name'] as String,
      r['admin1'] as String? ?? '',
      r['country'] as String? ?? '',
      (r['latitude'] as num).toDouble(),
      (r['longitude'] as num).toDouble(),
      r['country_code'] as String? ?? '',
    ),
];

Uri forecastUri(double lat, double lon, {bool fahrenheit = false}) => Uri.parse(
  'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon'
  '&current=temperature_2m,apparent_temperature,weather_code&timezone=auto'
  '${fahrenheit ? '&temperature_unit=fahrenheit' : ''}',
);

/// [language] is `en` or `pt`.
Uri geocodingUri(String query, String language) => Uri.parse(
  'https://geocoding-api.open-meteo.com/v1/search'
  '?name=${Uri.encodeComponent(query)}&count=5&language=$language&format=json',
);

/// The weather of the city in Settings. The last forecast is cached on disk, so
/// the home opens with it; the open app asks again every 30 minutes.
class WeatherSource extends ChangeNotifier {
  final Settings settings;
  final Store store;
  final Fetch _fetch;
  Timer? _timer;

  /// Null until there is a cached or fetched forecast.
  Weather? current;

  WeatherSource(this.settings, this.store, {this._fetch = getJson});

  /// Shows what the last run cached, even if the city has changed since: the
  /// first [refresh] replaces it. A cache this version cannot read is skipped,
  /// and so is any with no city set.
  Future<void> loadCache() async {
    if (settings.weatherCity.isEmpty) return;
    try {
      final cached = await store.read(_cache);
      if (cached == null) return;
      current = Weather.fromJson(cached['weather']);
      notifyListeners();
    } catch (_) {}
  }

  /// Asks Open-Meteo, unless the cache holds a forecast for this city and
  /// unit that is under 30 minutes old; [force] asks anyway. A failure of any
  /// kind leaves [current] as it was, and the next refresh tries again. An
  /// answer for a city or unit that is no longer the one in Settings is
  /// dropped. With no city there is no forecast.
  Future<void> refresh({bool force = false}) async {
    if (settings.weatherCity.isEmpty) {
      if (current != null) {
        current = null;
        notifyListeners();
      }
      return;
    }
    final lat = settings.weatherLat;
    final lon = settings.weatherLon;
    final f = settings.fahrenheit;
    try {
      if (!force && await _fresh(lat, lon, f)) return;
      final w = parseForecast(
        await _fetch(forecastUri(lat, lon, fahrenheit: f)),
      );
      // Another city or unit was picked while the call was out: the answer is
      // for the old one.
      if (settings.weatherLat != lat ||
          settings.weatherLon != lon ||
          settings.fahrenheit != f) {
        return;
      }
      if (!mapEquals(w.toJson(), current?.toJson())) {
        current = w;
        notifyListeners();
      }
      // Last, so a cache that will not write (a full disk) cannot undo a good
      // fetch. An unchanged forecast is still written: that renews its age.
      await store.write(_cache, {
        'weather': w.toJson(),
        'lat': lat,
        'lon': lon,
        'fahrenheit': f,
      });
    } catch (_) {
      // ponytail: no retry. A failed refresh waits for the next tick or resume;
      // retry once after a few seconds if a TV that boots before its Wi-Fi
      // leaves the line stale for too long.
    }
  }

  /// With nothing to show, the cache is no cache. A file from the future (the
  /// clock was off) is not fresh either.
  Future<bool> _fresh(double lat, double lon, bool fahrenheit) async {
    final at = await store.writtenAt(_cache);
    final cached = await store.read(_cache);
    if (current == null || at == null || cached == null) return false;
    final age = DateTime.now().difference(at);
    return !age.isNegative &&
        age < _every &&
        cached['lat'] == lat &&
        cached['lon'] == lon &&
        (cached['fahrenheit'] == true) == fahrenheit;
  }

  /// Refreshes at once, if due, and then every 30 minutes. Safe to call again.
  void start() {
    refresh();
    // The tick forces: it comes just under 30 minutes after the cache was
    // written, which would still count as fresh.
    _timer ??= Timer.periodic(_every, (_) => refresh(force: true));
  }

  /// Safe without a [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Up to five places called [query], named in the UI language; none when the
  /// network fails.
  Future<List<Place>> search(String query) async {
    try {
      final language = settings.language == 'pt' ? 'pt' : 'en';
      return parseGeocoding(await _fetch(geocodingUri(query, language)));
    } catch (_) {
      // ponytail: a failed search reads as no results; throw instead if the
      // settings pane should say "network error".
      return [];
    }
  }
}
