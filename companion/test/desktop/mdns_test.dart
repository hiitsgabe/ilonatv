import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/desktop/mdns.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Answers each query from [tvs] (instance name to host and port).
class FakeMdns implements MDnsClient {
  FakeMdns(this.tvs, {this.fails = false});
  final Map<String, (String, int)> tvs;
  final bool fails;
  var stopped = false;

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    if (fails) throw const SocketException('no multicast');
  }

  @override
  void stop() => stopped = true;

  @override
  Future<Iterable<NetworkInterface>> allInterfacesFactory(
    InternetAddressType type,
  ) async => const [];

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final q = query.fullyQualifiedName;
    final records = <ResourceRecord>[
      if (q == '_ilonatv._tcp.local')
        for (final name in tvs.keys)
          PtrResourceRecord(q, 0, domainName: '$name._ilonatv._tcp.local'),
      for (final MapEntry(key: name, value: (host, port)) in tvs.entries) ...[
        if (q == '$name._ilonatv._tcp.local')
          SrvResourceRecord(
            q,
            0,
            target: '$host.tv.local',
            port: port,
            priority: 0,
            weight: 0,
          ),
        if (q == '$host.tv.local')
          IPAddressResourceRecord(q, 0, address: InternetAddress(host)),
      ],
    ];
    return Stream.fromIterable(records.whereType<T>());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'finds a TV, moves it, and loses it after three missed rounds',
    () async {
      var answer = {'Ilona TV on X': ('10.0.0.5', 8642)};
      final clients = <FakeMdns>[];
      final d = MdnsDiscovery(
        client: () {
          final c = FakeMdns(answer);
          clients.add(c);
          return c;
        },
        every: const Duration(milliseconds: 5),
      );
      final events = <String>[];
      d.start(
        (name, host, port) => events.add('found $name $host:$port'),
        (name) => events.add('lost $name'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events, ['found Ilona TV on X 10.0.0.5:8642']);
      answer = {'Ilona TV on X': ('10.0.0.6', 8642)};
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(events.last, 'found Ilona TV on X 10.0.0.6:8642');
      answer = {};
      await Future<void>.delayed(const Duration(milliseconds: 60));
      d.stop();
      expect(events.last, 'lost Ilona TV on X');
      expect(events.where((e) => e.startsWith('lost')), hasLength(1));
      // A fresh client each round, so no cached answer keeps a TV that left.
      expect(clients.every((c) => c.stopped), isTrue);
    },
  );

  test(
    'no multicast finds nothing and keeps trying, without throwing',
    () async {
      var tries = 0;
      final d = MdnsDiscovery(
        client: () {
          tries++;
          return FakeMdns(const {}, fails: true);
        },
        every: const Duration(milliseconds: 5),
      );
      final found = <String>[];
      d.start((name, _, _) => found.add(name), (_) {});
      await Future<void>.delayed(const Duration(milliseconds: 30));
      d.stop();
      final after = tries;
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(found, isEmpty);
      expect(after, greaterThan(1));
      expect(tries, after, reason: 'stop ends the rounds');
    },
  );

  group('Tvs on desktop', () {
    final calls = <String>[];
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('tv.ilona.companion/host'),
            (c) async {
              calls.add(c.method);
              return null;
            },
          );
    });
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('discovers over mDNS, never the Android channel', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      final tvs = Tvs(
        discovery: MdnsDiscovery(
          client: () => FakeMdns({'Ilona TV on X': ('10.0.0.5', 8642)}),
          every: const Duration(milliseconds: 5),
        ),
      );
      await tvs.load();
      tvs.startDiscovery();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(tvs.all.single.host, '10.0.0.5');
      expect(tvs.all.single.label, 'Ilona TV');
      tvs.stopDiscovery();
      expect(tvs.all, isEmpty);
      expect(calls, isEmpty);
    });

    test('picks mDNS by itself on macOS and Windows only', () {
      for (final os in [TargetPlatform.macOS, TargetPlatform.windows]) {
        debugDefaultTargetPlatformOverride = os;
        Tvs()
          ..startDiscovery()
          ..stopDiscovery();
      }
      expect(calls, isEmpty);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      Tvs()
        ..startDiscovery()
        ..stopDiscovery();
      expect(calls, ['discoverStart', 'discoverStop']);
    });
  });
}
