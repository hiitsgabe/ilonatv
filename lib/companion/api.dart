import 'dart:convert';

import 'package:ilonatv_protocol/ilonatv_protocol.dart';

import '../data/media.dart';
import '../data/tmdb.dart';
import '../data/weather.dart';
import '../host.dart';
import '../i18n.dart';
import '../net.dart' show kRequestTimeout;
import '../providers.dart' show openItem;
import '../settings.dart';
import '../sources.dart';
import 'server.dart';
import 'state.dart';

const _max = 20;
const _maxQuery = 200;
const _maxKey = 64;
const _maxName = 100;
const _maxItem = 8 * 1024;
const _maxText = 500;
// Empty as Open-Meteo leaves it for a place with no country.
final _countryCode = RegExp(r'^([A-Za-z]{2})?$');
const _badRequest = (400, {'error': 'badRequest'});
const _notFound = (404, {'error': 'notFound'});

/// Where a remote key goes: Ilona TV's window, the accessibility service's
/// global actions (another app in front), the audio service, or nowhere.
enum KeyRoute { window, global, audio, none }

const _audioKeys = {
  RemoteKey.volumeUp,
  RemoteKey.volumeDown,
  RemoteKey.mute,
  RemoteKey.playPause,
};

/// What the remote reaches while another app is in front. The D-pad's global
/// actions came in API 33; Back and Home are older. All need the service.
String keysOutside({required int api, required bool service}) => !service
    ? 'none'
    : api >= 33
    ? 'all'
    : 'backHome';

KeyRoute keyRoute(
  RemoteKey k, {
  required bool inFront,
  required String keysOutside,
}) {
  if (_audioKeys.contains(k)) return KeyRoute.audio;
  if (inFront) return KeyRoute.window;
  return switch (keysOutside) {
    'all' => KeyRoute.global,
    'backHome' when k == RemoteKey.back || k == RemoteKey.home =>
      KeyRoute.global,
    _ => KeyRoute.none,
  };
}

/// What a paired phone can do: what the TV's own screens do, with the TV's
/// code. Answers carry display data only, never a key or a token.
class IlonaTvApi implements CompanionApi {
  IlonaTvApi(
    this.settings,
    this.sources, {
    this.injectKey = Host.injectKey,
    this.globalKey = Host.globalKey,
    this.audioKey = Host.audioKey,
    this.keyAccess = Host.keyAccess,
    this.typeText = Host.typeText,
  });

  final Settings settings;
  final Sources sources;
  final Future<bool> Function(RemoteKey) injectKey;
  final Future<bool> Function(RemoteKey) globalKey;
  final Future<bool> Function(RemoteKey) audioKey;
  final Future<({int api, bool service})> Function() keyAccess;

  /// Replaces the text of the focused field, in whatever app is in front;
  /// false when none has focus.
  final Future<bool> Function(String) typeText;

  Future<String> _keysOutside() async {
    final a = await keyAccess();
    return keysOutside(api: a.api, service: a.service);
  }

  /// For /api/info: the phone sends over ADB what the TV can't do itself.
  Future<Map<String, Object>> outside() async {
    final a = await keyAccess();
    return {
      'keysOutside': keysOutside(api: a.api, service: a.service),
      'api': a.api,
    };
  }

  @override
  Future<(int, Object)> handle(
    String method,
    String path,
    Map<String, String> query,
    Object? body,
  ) async {
    final b = body is Map ? body : const {};
    return switch ((method, path)) {
      ('POST', '/api/key') => _key(b['key']),
      ('POST', '/api/text') => _text(b['text']),
      ('GET', '/api/search') => _search(query['q']?.trim() ?? ''),
      ('GET', '/api/rows') => (200, _rows()),
      ('POST', '/api/open') => _open(b['item']),
      ('POST', '/api/setup/tmdb') => _tmdb(b['key'], b['save']),
      ('GET', '/api/setup/cities') => _cities(query['q']?.trim() ?? ''),
      ('POST', '/api/setup/city') => _city(b),
      _ => _notFound,
    };
  }

  Future<(int, Object)> _key(Object? name) async {
    final key = name is String ? remoteKeyByName(name) : null;
    if (key == null) return _badRequest;
    final inFront = companionState.inFront;
    final route = keyRoute(
      key,
      inFront: inFront,
      keysOutside: inFront ? 'none' : await _keysOutside(),
    );
    final sent = switch (route) {
      KeyRoute.window => await injectKey(key),
      KeyRoute.global => await globalKey(key),
      KeyRoute.audio => await audioKey(key),
      KeyRoute.none => false,
    };
    if (!sent) return (409, {'error': 'notInFront'});
    return (204, const {});
  }

  Future<(int, Object)> _text(Object? text) async {
    if (text is! String || text.length > _maxText) return _badRequest;
    if (!await typeText(text)) return (409, {'error': 'noField'});
    return (204, const {});
  }

  Future<(int, Object)> _search(String q) async {
    if (q.isEmpty || q.length > _maxQuery) return _badRequest;
    final tmdb = sources.tmdb.client;
    Future<List<Object>> safe(Future<List<MediaItem>> f) =>
        f.then(_items, onError: (_) => const <Object>[]);
    final (movies, series, videos) = await (
      safe(tmdb.search(MediaType.movie, q)),
      safe(tmdb.search(MediaType.series, q)),
      // YouTube's chain is several requests long; it gets no more than one.
      safe(
        sources.youtube
            .searchFirstAccount(q)
            .timeout(kRequestTimeout, onTimeout: () => const []),
      ),
    ).wait;
    return (200, {'movies': movies, 'series': series, 'videos': videos});
  }

  List<Object> _rows() => [
    for (final (key, items) in settings.shownRows(sources.rowItems()))
      {'key': key, 'title': rowTitle(key), 'items': _items(items)},
  ];

  Future<(int, Object)> _open(Object? json) async {
    final MediaItem item;
    try {
      if (jsonEncode(json).length > _maxItem) return _badRequest;
      item = MediaItem.fromJson(json as Map);
    } catch (_) {
      return _badRequest;
    }
    if (item.type case MediaType.game || MediaType.input) return _badRequest;
    // Android blocks a background app's start unless it is the home app.
    if (!companionState.inFront && !settings.fireTvMode) {
      return (409, {'error': 'notInFront'});
    }
    final opened = await openItem(
      item,
      settings,
      sources.tmdb,
      lastVideo: sources.stremio.lastVideo,
    );
    return (200, {'opened': opened});
  }

  Future<(int, Object)> _tmdb(Object? key, Object? save) async {
    if (key is! String || save is! bool?) return _badRequest;
    final k = key.trim();
    if (k.length > _maxKey) return _badRequest;
    String result;
    try {
      await sources.tmdb.testKey(k);
      result = 'keyOk';
    } on TmdbError catch (e) {
      result = e == TmdbError.badKey ? 'keyBad' : 'networkError';
    } catch (_) {
      result = 'networkError';
    }
    if (result == 'keyOk' && save == true) {
      settings.tmdbKey = k;
      await settings.save();
      sources.tmdb.refresh(force: true).ignore();
    }
    return (200, {'result': result});
  }

  Future<(int, Object)> _cities(String q) async {
    if (q.isEmpty || q.length > _maxQuery) return _badRequest;
    final places = await sources.weather.search(q);
    return (
      200,
      [
        for (final p in places.take(_max))
          {
            'name': p.name,
            'region': p.region,
            'country': p.country,
            'lat': p.lat,
            'lon': p.lon,
            'countryCode': p.countryCode,
          },
      ],
    );
  }

  Future<(int, Object)> _city(Map b) async {
    if (b
        case {
          'name': final String name,
          'region': final String region,
          'country': final String country,
          'lat': final num lat,
          'lon': final num lon,
          'countryCode': final String countryCode,
        }
        when name.isNotEmpty &&
            name.length <= _maxName &&
            region.length <= _maxName &&
            country.length <= _maxName &&
            _countryCode.hasMatch(countryCode) &&
            lat.abs() <= 90 &&
            lon.abs() <= 180) {
      await settings.applyPlace(
        Place(
          name,
          region,
          country,
          lat.toDouble(),
          lon.toDouble(),
          countryCode,
        ),
      );
      sources.weather.refresh(force: true).ignore();
      return (204, const {});
    }
    return _badRequest;
  }

  static List<Object> _items(List<MediaItem> items) => [
    for (final i in items.take(_max)) i.toJson(),
  ];
}
