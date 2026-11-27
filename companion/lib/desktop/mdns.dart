import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import '../tvs.dart';

const _type = '_ilonatv._tcp.local';

/// The TVs' `_ilonatv._tcp` over mDNS, asked again every [every]; a TV that
/// misses three rounds in a row is lost.
class MdnsDiscovery implements Discovery {
  MdnsDiscovery({
    this.client = MDnsClient.new,
    this.every = const Duration(seconds: 5),
    this.window = const Duration(seconds: 3),
  });

  final MDnsClient Function() client;
  final Duration every;

  /// How long a round listens for answers.
  final Duration window;

  int _gen = 0;
  final _at = <String, (String, int)>{};
  final _misses = <String, int>{};

  @override
  void start(
    void Function(String name, String host, int port) found,
    void Function(String name) lost,
  ) => _loop(++_gen, found, lost);

  @override
  void stop() {
    _gen++;
    _at.clear();
    _misses.clear();
  }

  Future<void> _loop(
    int g,
    void Function(String, String, int) found,
    void Function(String) lost,
  ) async {
    // A start and stop in the same turn opens no socket.
    await Future<void>.value();
    while (g == _gen) {
      final round = await _round();
      if (g != _gen) return;
      for (final MapEntry(key: name, value: at) in round.entries) {
        _misses.remove(name);
        if (_at[name] == at) continue;
        _at[name] = at;
        found(name, at.$1, at.$2);
      }
      for (final name in [..._at.keys]) {
        if (round.containsKey(name)) continue;
        final m = _misses[name] = (_misses[name] ?? 0) + 1;
        if (m < 3) continue;
        _at.remove(name);
        _misses.remove(name);
        lost(name);
      }
      await Future<void>.delayed(every);
    }
  }

  // A fresh client each round: its cache would keep a TV that left for as long as the PTR's TTL.
  Future<Map<String, (String, int)>> _round() async {
    final c = client();
    final out = <String, (String, int)>{};
    try {
      await c.start();
      final ptrs = await c
          .lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(_type),
            timeout: window,
          )
          .map((p) => p.domainName)
          .toSet();
      for (final service in ptrs) {
        final srv = await _first(
          c.lookup<SrvResourceRecord>(
            ResourceRecordQuery.service(service),
            timeout: window,
          ),
        );
        if (srv == null) continue;
        // IPv4 only: the TV serves on it, as on Android.
        final ip = await _first(
          c.lookup<IPAddressResourceRecord>(
            ResourceRecordQuery.addressIPv4(srv.target),
            timeout: window,
          ),
        );
        if (ip == null) continue;
        final name = service.endsWith('.$_type')
            ? service.substring(0, service.length - _type.length - 1)
            : service;
        out[name] = (ip.address.address, srv.port);
      }
    } catch (_) {
      // No multicast here (a firewall, no network): typing the TV's address still works.
    } finally {
      try {
        c.stop();
      } catch (_) {}
    }
    return out;
  }
}

Future<T?> _first<T>(Stream<T> s) async {
  await for (final x in s) {
    return x;
  }
  return null;
}
