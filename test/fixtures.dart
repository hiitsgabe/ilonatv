import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:ilonatv/net.dart';
import 'package:ilonatv/store.dart';
import 'package:flutter_test/flutter_test.dart' show pumpEventQueue;

/// A canned service response, read from `test/fixtures/<name>`. `flutter test`
/// runs from the project root.
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name').readAsStringSync());

/// A canned network for a source: `call` answers a request with the fixture of
/// the first route whose key the request's path contains, so list the routes
/// from the most specific to the least. A path no route covers is a
/// [StateError]. Every request is noted in `calls`, answered or not.
({Fetch call, List<Uri> calls}) fake(Map<String, String> pathToFixture) {
  final calls = <Uri>[];

  Future<Map<String, dynamic>> call(
    Uri uri, {
    Map<String, String> headers = const {},
  }) async {
    calls.add(uri);
    for (final MapEntry(:key, :value) in pathToFixture.entries) {
      if (uri.path.contains(key)) return fixture(value);
    }
    throw StateError('no fixture for ${uri.path}');
  }

  return (call: call, calls: calls);
}

/// [fake] for a POST: the same routes, and `calls` also notes each request's
/// body.
({Post call, List<(Uri, Map<String, dynamic>)> calls}) fakePost(
  Map<String, String> pathToFixture,
) {
  final calls = <(Uri, Map<String, dynamic>)>[];

  Future<Map<String, dynamic>> call(
    Uri uri,
    Map<String, dynamic> body, {
    Map<String, String> headers = const {},
  }) async {
    calls.add((uri, body));
    for (final MapEntry(:key, :value) in pathToFixture.entries) {
      if (uri.path.contains(key)) return fixture(value);
    }
    throw StateError('no fixture for ${uri.path}');
  }

  return (call: call, calls: calls);
}

/// A disk with no room left: reads work, writes fail.
class FullDiskStore extends Store {
  FullDiskStore(super.dir);

  @override
  Future<void> write(String name, Map<String, dynamic> json) async =>
      throw const FileSystemException('No space left on device');
}

/// A cache in memory, so a test of timing has no real I/O left running when it
/// ends.
class MemStore extends Store {
  MemStore() : super(Directory('unused'));
  final _entries = <String, Map<String, dynamic>>{};
  final _at = <String, DateTime>{};
  final bytes = <String, Uint8List>{};

  @override
  Future<Uint8List?> readBytes(String name) async => bytes[name];

  @override
  Future<void> writeBytes(String name, Uint8List data) async =>
      bytes[name] = data;

  @override
  Future<Map<String, dynamic>?> read(String name) async => _entries[name];

  @override
  Future<DateTime?> writtenAt(String name) async => _at[name];

  @override
  Future<void> write(String name, Map<String, dynamic> json) async {
    _entries[name] = json;
    _at[name] = DateTime.now();
  }
}

/// A periodic timer that never ticks by itself; the test fires it.
class FakeTimer implements Timer {
  FakeTimer(this.period, this._callback);
  final Duration period;
  final void Function(Timer) _callback;
  var _active = true;

  void fire() => _callback(this);

  /// [fire], then lets what the callback started run to its end. (Not `tick`:
  /// a [Timer] has a getter of that name.) The zone hands the callback back
  /// wrapped, with no future to await, so the test waits for the event queue.
  Future<void> fireAndSettle() async {
    fire();
    await pumpEventQueue();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;
}

/// A zone in which every periodic timer is a [FakeTimer], kept in [timers] in
/// the order they were made. Run the code under test in it with [run].
class FakeTimerZone {
  final timers = <FakeTimer>[];

  late final _zone = Zone.current.fork(
    specification: ZoneSpecification(
      createPeriodicTimer: (_, _, _, period, callback) {
        final timer = FakeTimer(period, callback);
        timers.add(timer);
        return timer;
      },
    ),
  );

  T run<T>(T Function() body) => _zone.run(body);
}
