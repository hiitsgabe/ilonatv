import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'desktop/adb.dart';
import 'desktop/host.dart';

const kAdbPort = 5555;

enum AdbResult { ok, unauthorized, unreachable }

class ShellResult {
  const ShellResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

/// Android's KeyEvent codes, for `input keyevent`.
const adbKeycodes = {
  RemoteKey.up: 19,
  RemoteKey.down: 20,
  RemoteKey.left: 21,
  RemoteKey.right: 22,
  RemoteKey.ok: 23,
  RemoteKey.back: 4,
  RemoteKey.home: 3,
  RemoteKey.volumeUp: 24,
  RemoteKey.volumeDown: 25,
  RemoteKey.mute: 164,
  RemoteKey.playPause: 85,
};

const mediaKeys = {
  RemoteKey.volumeUp,
  RemoteKey.volumeDown,
  RemoteKey.mute,
  RemoteKey.playPause,
};

/// Whether [k] goes over ADB rather than to the TV's server, by what the TV
/// says it reaches outside its own app ([TvInfo.keysOutside]). A TV older than
/// that field has no media keys and reaches nothing outside.
bool useAdb(
  RemoteKey k, {
  required bool inFront,
  required String? keysOutside,
  bool adbUp = false,
}) {
  if (keysOutside == null) return !inFront;
  // `input keyevent` goes through the system, so volume reaches the set over
  // CEC, where Fire TV's own AudioManager volume is often fixed.
  if (mediaKeys.contains(k)) return adbUp && keysOutside != 'all';
  if (inFront) return false;
  return switch (keysOutside) {
    'all' => false,
    'backHome' => k != RemoteKey.back && k != RemoteKey.home,
    _ => true,
  };
}

/// What runs ADB: Adb.kt over a channel on Android, the adb binary on desktop.
abstract interface class AdbBackend {
  /// Whether adb can run now; on desktop, not until platform-tools is here.
  bool get ready;

  /// Fetches Google's platform-tools, once the person agreed to its terms.
  Future<void> download({void Function(int got, int total)? progress});
  Future<AdbResult> connect(String host, int port);

  /// Android 11+'s Wireless debugging pairing; null when paired, else why.
  Future<String?> pair(String host, int port, String code);
  Future<ShellResult> shell(String cmd);
  Future<bool> key(int code);

  /// Null when installed, else why not.
  Future<String?> install(String path);
  Future<void> close();
}

/// ADB to the TV over the network: the installer, and the remote's keys
/// while another app is in front.
class Adb {
  Adb([AdbBackend? backend])
    : _b = backend ?? (isDesktop ? _desktop : const _ChannelAdb());

  // One for the app, as Adb.kt is one on Android.
  static final _desktop = DesktopAdb();

  final AdbBackend _b;
  static const _known = 'adbHosts';

  /// A TV that allowed this phone before: connecting again shows no prompt.
  Future<bool> knows(String host) async =>
      (await SharedPreferences.getInstance())
          .getStringList(_known)
          ?.contains(host) ??
      false;

  Future<void> _remember(String host) async {
    final prefs = await SharedPreferences.getInstance();
    final hosts = prefs.getStringList(_known) ?? const [];
    if (hosts.contains(host)) return;
    await prefs.setStringList(_known, [...hosts, host]);
  }

  bool get ready => _b.ready;

  Future<void> download({void Function(int got, int total)? progress}) =>
      _b.download(progress: progress);

  /// Waits for the TV's "Allow debugging?" prompt, up to 60 s.
  Future<AdbResult> connect(String host, int port) async {
    final r = await _b.connect(host, port);
    if (r == AdbResult.ok) await _remember(host);
    return r;
  }

  Future<String?> pair(String host, int port, String code) =>
      _b.pair(host, port, code);

  Future<ShellResult> shell(String cmd) => _b.shell(cmd);

  /// False when the connection is gone, or after 3 s, so a stuck connection
  /// never holds up the keys behind it.
  Future<bool> key(RemoteKey k) => _b.key(adbKeycodes[k]!);

  Future<String?> install(String path) => _b.install(path);

  Future<void> close() => _b.close();
}

/// Through Adb.kt (dadb).
class _ChannelAdb implements AdbBackend {
  const _ChannelAdb();

  static const _channel = MethodChannel('tv.ilona.companion/adb');

  @override
  bool get ready => true;

  @override
  Future<void> download({void Function(int got, int total)? progress}) async {}

  @override
  Future<String?> pair(String host, int port, String code) async =>
      'unsupported';

  /// Adb.kt gives up after 60 s.
  @override
  Future<AdbResult> connect(String host, int port) async {
    try {
      final r = await _channel
          .invokeMethod<String>('connect', {'host': host, 'port': port})
          // Past Adb.kt's own 60 s, so a native side that never answers still ends.
          .timeout(const Duration(seconds: 65));
      return AdbResult.values.firstWhere(
        (v) => v.name == r,
        orElse: () => AdbResult.unreachable,
      );
    } on TimeoutException {
      return AdbResult.unauthorized;
    } on PlatformException {
      return AdbResult.unreachable;
    }
  }

  @override
  Future<ShellResult> shell(String cmd) async {
    try {
      final r = await _channel.invokeMapMethod<String, Object?>('shell', {
        'cmd': cmd,
      });
      return ShellResult(r!['exitCode'] as int, r['output'] as String);
    } on PlatformException catch (e) {
      return ShellResult(-1, e.message ?? e.code);
    }
  }

  /// Through one shell kept open on the connection.
  @override
  Future<bool> key(int code) async {
    try {
      await _channel
          .invokeMethod<void>('key', {'code': code})
          .timeout(const Duration(seconds: 3));
      return true;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  @override
  Future<String?> install(String path) async {
    try {
      final r = await _channel.invokeMethod<Object?>('install', {'path': path});
      return r == 'ok' ? null : (r as Map)['error'] as String;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  @override
  Future<void> close() => _channel.invokeMethod<void>('close');
}
