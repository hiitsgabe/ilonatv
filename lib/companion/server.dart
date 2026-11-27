import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:flutter/foundation.dart';

import '../app.dart' show kVersion;
import 'pairing.dart';
import 'state.dart';

const _maxBody = 64 * 1024;

abstract class CompanionApi {
  Future<(int status, Object body)> handle(
    String method,
    String path,
    Map<String, String> query,
    Object? body,
  );
}

class _TooLarge implements Exception {}

class CompanionServer {
  CompanionServer(
    this.pairing,
    this.api, {
    this.port = kCompanionPort,
    this.address,
    this.outside,
  });

  final Pairing pairing;
  final CompanionApi api;
  final int port;
  final InternetAddress? address;
  final Future<Map<String, Object>> Function()? outside;

  HttpServer? _server;
  Future<void>? _starting;
  final _sockets = <WebSocket, String>{};

  int get boundPort => _server?.port ?? 0;

  Future<void> start() async {
    final starting = _starting ??= _bind();
    try {
      await starting;
    } catch (_) {
      if (identical(_starting, starting)) _starting = null;
      rethrow;
    }
  }

  Future<void> _bind() async {
    final s = await HttpServer.bind(address ?? InternetAddress.anyIPv4, port);
    _server = s;
    companionState.addListener(_onState);
    pairing.addListener(_onPairing);
    s.listen(_handle);
  }

  Future<void> stop() async {
    final starting = _starting;
    _starting = null;
    try {
      await starting;
    } catch (_) {}
    companionState.removeListener(_onState);
    pairing.removeListener(_onPairing);
    final sockets = _sockets.keys.toList();
    _sockets.clear();
    await Future.wait(sockets.map((ws) => ws.close(WebSocketStatus.goingAway)));
    await _server?.close(force: true);
    _server = null;
  }

  Map<String, dynamic> get _state => {
    'step': companionState.step?.name,
    'inFront': companionState.inFront,
    'launcherMode': pairing.settings.fireTvMode,
    // ARGB, so the phone takes on the colour picked on the TV.
    'accent': pairing.settings.assistantColor,
  };

  // A platform call: it can fail with no engine to answer, and the rest stands.
  Future<Map<String, dynamic>> _full() async {
    try {
      final extra = await outside?.call();
      return {..._state, ...?extra};
    } catch (_) {
      return _state;
    }
  }

  Future<void> _onState() async {
    final e = TvEvent('state', await _full()).encode();
    for (final ws in _sockets.keys) {
      ws.add(e);
    }
  }

  void _onPairing() {
    for (final MapEntry(key: ws, value: token) in _sockets.entries.toList()) {
      if (pairing.isValid(token)) continue;
      _sockets.remove(ws);
      ws.add(const TvEvent('bye').encode());
      ws.close(WebSocketStatus.policyViolation);
    }
  }

  Future<void> _handle(HttpRequest req) async {
    try {
      await _route(req);
    } catch (e, s) {
      debugPrint('companion server: $e\n$s');
      try {
        await _json(req.response, 500, {'error': 'internal'});
      } catch (_) {}
    }
  }

  Future<void> _route(HttpRequest req) async {
    final path = req.uri.path;
    final method = req.method;
    if (method == 'GET' && path == '/') {
      req.response.headers.contentType = ContentType.html;
      req.response.write(
        '<!doctype html><title>Ilona TV</title>Ilona TV is running',
      );
      return req.response.close();
    }
    if (method == 'POST' && path == '/api/pair') return _pair(req);

    final isEvents = method == 'GET' && path == '/api/events';
    final token = isEvents ? req.uri.queryParameters['token'] : _bearer(req);
    if (token == null || !pairing.isValid(token)) {
      return _json(req.response, 401, {'error': 'unauthorized'});
    }
    if (isEvents) return _events(req, token);
    if (method == 'GET' && path == '/api/info') {
      return _json(req.response, 200, {
        'protocol': kProtocolVersion,
        'version': kVersion,
        ...await _full(),
      });
    }

    final Object? body;
    try {
      final text = await _body(req);
      body = text.isEmpty ? null : jsonDecode(text);
    } on _TooLarge {
      return _json(req.response, 413, {'error': 'tooLarge'});
    } on FormatException {
      return _json(req.response, 400, {'error': 'badRequest'});
    }
    final (status, out) = await api.handle(
      method,
      path,
      req.uri.queryParameters,
      body,
    );
    return _json(req.response, status, out);
  }

  Future<void> _pair(HttpRequest req) async {
    final PairRequest r;
    try {
      final j = jsonDecode(await _body(req));
      if (j is! Map) throw const FormatException('not an object');
      r = PairRequest.fromJson(j);
    } on _TooLarge {
      return _json(req.response, 413, {'error': 'tooLarge'});
    } on FormatException {
      return _json(req.response, 400, {'error': 'badRequest'});
    }
    final token = await pairing.pair(r);
    if (token == null) {
      return _json(req.response, 403, {'error': 'badPairing'});
    }
    return _json(req.response, 200, {'token': token});
  }

  Future<void> _events(HttpRequest req, String token) async {
    if (!WebSocketTransformer.isUpgradeRequest(req)) {
      return _json(req.response, 400, {'error': 'badRequest'});
    }
    final ws = await WebSocketTransformer.upgrade(req);
    // Remove or stop may have run during the upgrade, and missed this socket.
    if (_server == null || !pairing.isValid(token)) {
      ws.add(const TvEvent('bye').encode());
      await ws.close(WebSocketStatus.policyViolation);
      return;
    }
    _sockets[ws] = token;
    ws.listen(
      (_) {},
      onDone: () => _sockets.remove(ws),
      onError: (_) => _sockets.remove(ws),
    );
    ws.add(TvEvent('state', await _full()).encode());
  }

  String? _bearer(HttpRequest req) {
    final h = req.headers.value(HttpHeaders.authorizationHeader);
    if (h == null || !h.startsWith('Bearer ')) return null;
    return h.substring(7);
  }

  Future<String> _body(HttpRequest req) async {
    if (req.contentLength > _maxBody) throw _TooLarge();
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in req) {
      bytes.add(chunk);
      if (bytes.length > _maxBody) throw _TooLarge();
    }
    return utf8.decode(bytes.takeBytes());
  }

  Future<void> _json(HttpResponse r, int status, Object body) {
    r.statusCode = status;
    r.headers.contentType = ContentType.json;
    r.write(jsonEncode(body));
    return r.close();
  }
}
