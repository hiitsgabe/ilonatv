import 'dart:async';

import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

/// ADB to the TV over the network, through Adb.kt (dadb): the installer, and
/// the remote's keys while another app is in front.
class Adb {
  static const _channel = MethodChannel('tv.ilona.companion/adb');
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

  /// Waits for the TV's "Allow debugging?" prompt; Adb.kt gives up after 60 s.
  Future<AdbResult> connect(String host, int port) async {
    try {
      final r = await _channel
          .invokeMethod<String>('connect', {'host': host, 'port': port})
          // Past Adb.kt's own 60 s, so a native side that never answers still ends.
          .timeout(const Duration(seconds: 65));
      final result = AdbResult.values.firstWhere(
        (v) => v.name == r,
        orElse: () => AdbResult.unreachable,
      );
      if (result == AdbResult.ok) await _remember(host);
      return result;
    } on TimeoutException {
      return AdbResult.unauthorized;
    } on PlatformException {
      return AdbResult.unreachable;
    }
  }

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

  /// Through one shell kept open on the connection; false when it is gone, or
  /// after 3 s, so a stuck connection never holds up the keys behind it.
  Future<bool> key(RemoteKey k) async {
    try {
      await _channel
          .invokeMethod<void>('key', {'code': adbKeycodes[k]})
          .timeout(const Duration(seconds: 3));
      return true;
    } on PlatformException {
      return false;
    } on TimeoutException {
      return false;
    }
  }

  /// Null when installed, else why not.
  Future<String?> install(String path) async {
    try {
      final r = await _channel.invokeMethod<Object?>('install', {'path': path});
      return r == 'ok' ? null : (r as Map)['error'] as String;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    }
  }

  Future<void> close() => _channel.invokeMethod<void>('close');
}
