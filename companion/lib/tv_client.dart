import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ilonatv_protocol/ilonatv_protocol.dart';

const _timeout = Duration(seconds: 10);

sealed class TvResult<T> {
  const TvResult();
}

class Ok<T> extends TvResult<T> {
  const Ok(this.value);
  final T value;
}

class Unpaired<T> extends TvResult<T> {
  const Unpaired();
}

class NotInFront<T> extends TvResult<T> {
  const NotInFront({required this.launcherMode});
  final bool launcherMode;
}

class Unreachable<T> extends TvResult<T> {
  const Unreachable(this.why);
  final String why;
}

class Refused<T> extends TvResult<T> {
  const Refused(this.status, this.error);
  final int status;
  final String? error;
}

class TvInfo {
  const TvInfo({
    required this.protocol,
    required this.version,
    this.step,
    required this.inFront,
    required this.launcherMode,
  });

  final int protocol;
  final String version;
  final String? step;
  final bool inFront;
  final bool launcherMode;

  factory TvInfo.fromJson(Map j) => TvInfo(
    protocol: j['protocol'] as int? ?? 0,
    version: j['version'] as String? ?? '',
    step: j['step'] as String?,
    inFront: j['inFront'] as bool? ?? false,
    launcherMode: j['launcherMode'] as bool? ?? false,
  );
}

class Place {
  const Place({
    required this.name,
    required this.region,
    required this.country,
    required this.countryCode,
    required this.lat,
    required this.lon,
  });

  final String name, region, country, countryCode;
  final double lat, lon;

  factory Place.fromJson(Map j) => Place(
    name: j['name'] as String,
    region: j['region'] as String? ?? '',
    country: j['country'] as String? ?? '',
    countryCode: j['countryCode'] as String? ?? '',
    lat: (j['lat'] as num).toDouble(),
    lon: (j['lon'] as num).toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'region': region,
    'country': country,
    'lat': lat,
    'lon': lon,
    'countryCode': countryCode,
  };
}

typedef Item = Map<String, dynamic>;

class SearchResults {
  const SearchResults(this.movies, this.series, this.videos);
  final List<Item> movies, series, videos;
}

class TvRow {
  const TvRow(this.key, this.title, this.items);
  final String key, title;
  final List<Item> items;
}

List<Item> _items(Object? l) => [
  for (final i in l as List? ?? const []) Map<String, dynamic>.from(i as Map),
];

class TvClient {
  TvClient(
    this.host, {
    this.port = kCompanionPort,
    this.token,
    HttpClient? http,
  }) : _http = http ?? HttpClient();

  final String host;
  final int port;
  final String? token;
  final HttpClient _http;

  Future<TvResult<(int, Object?)>> _raw(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
  }) async {
    try {
      return await (() async {
        final uri = Uri(
          scheme: 'http',
          host: host,
          port: port,
          path: path,
          queryParameters: query,
        );
        final req = await _http.openUrl(method, uri);
        if (auth && token != null) {
          req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        if (body != null) {
          req.headers.contentType = ContentType.json;
          req.write(jsonEncode(body));
        }
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join();
        Object? json;
        try {
          json = text.isEmpty ? null : jsonDecode(text);
        } on FormatException {
          json = null;
        }
        return Ok((res.statusCode, json));
      })().timeout(_timeout);
    } on TimeoutException {
      return const Unreachable('timeout');
    } on SocketException catch (e) {
      return Unreachable(e.message);
    } on HttpException catch (e) {
      return Unreachable(e.message);
    }
  }

  Future<TvResult<T>> _call<T>(
    String method,
    String path,
    T Function(Object? json) parse, {
    Object? body,
    Map<String, String>? query,
    bool auth = true,
    Future<TvResult<T>> Function()? on409,
  }) async {
    final r = await _raw(method, path, body: body, query: query, auth: auth);
    if (r is! Ok<(int, Object?)>) {
      return switch (r) {
        Unreachable(:final why) => Unreachable(why),
        _ => const Unreachable('unexpected'),
      };
    }
    final (status, json) = r.value;
    if (status == 401 || status == 403) return const Unpaired();
    if (status == 409 && on409 != null) return on409();
    if (status >= 400) {
      return Refused(status, json is Map ? json['error'] as String? : null);
    }
    try {
      return Ok(parse(json));
    } catch (_) {
      return Refused(status, 'badResponse');
    }
  }

  Future<TvResult<T>> _notInFront<T>() async {
    final i = await info();
    return NotInFront(launcherMode: i is Ok<TvInfo> && i.value.launcherMode);
  }

  Future<TvResult<String>> pair({
    String? code,
    String? secret,
    required String name,
  }) => _call(
    'POST',
    '/api/pair',
    (j) => (j as Map)['token'] as String,
    body: PairRequest(code: code, secret: secret, name: name).toJson(),
    auth: false,
  );

  Future<TvResult<TvInfo>> info() =>
      _call('GET', '/api/info', (j) => TvInfo.fromJson(j as Map));

  Future<TvResult<void>> key(RemoteKey k) => _call<void>(
    'POST',
    '/api/key',
    (_) {},
    body: {'key': k.name},
    on409: _notInFront,
  );

  Future<TvResult<SearchResults>> search(String q) =>
      _call('GET', '/api/search', (j) {
        final m = j as Map;
        return SearchResults(
          _items(m['movies']),
          _items(m['series']),
          _items(m['videos']),
        );
      }, query: {'q': q});

  Future<TvResult<List<TvRow>>> rows() => _call(
    'GET',
    '/api/rows',
    (j) => [
      for (final r in j as List)
        TvRow(r['key'] as String, r['title'] as String, _items(r['items'])),
    ],
  );

  Future<TvResult<bool>> open(Map item) => _call(
    'POST',
    '/api/open',
    (j) => (j as Map)['opened'] == true,
    body: {'item': item},
    on409: _notInFront,
  );

  Future<TvResult<String>> setupTmdb(String key, {bool save = true}) => _call(
    'POST',
    '/api/setup/tmdb',
    (j) => (j as Map)['result'] as String,
    body: {'key': key, 'save': save},
  );

  Future<TvResult<List<Place>>> cities(String q) => _call(
    'GET',
    '/api/setup/cities',
    (j) => [for (final p in j as List) Place.fromJson(p as Map)],
    query: {'q': q},
  );

  Future<TvResult<void>> setCity(Place p) =>
      _call<void>('POST', '/api/setup/city', (_) {}, body: p.toJson());

  Stream<TvInfo> events() async* {
    final WebSocket ws;
    try {
      ws = await WebSocket.connect(
        'ws://$host:$port/api/events?token=${Uri.encodeQueryComponent(token ?? '')}',
        customClient: _http,
      ).timeout(_timeout);
    } catch (_) {
      return;
    }
    try {
      await for (final m in ws) {
        if (m is! String) continue;
        final TvEvent e;
        try {
          e = TvEvent.decode(m);
        } on FormatException {
          continue;
        }
        if (e.type == 'bye') return;
        if (e.type == 'state') {
          yield TvInfo.fromJson({'protocol': kProtocolVersion, ...e.data});
        }
      }
    } catch (_) {
      // a dropped socket ends the stream like a close
    } finally {
      await ws.close();
    }
  }
}
