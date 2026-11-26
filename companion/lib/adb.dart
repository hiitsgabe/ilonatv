import 'dart:async';

import 'package:flutter/services.dart';

enum AdbResult { ok, unauthorized, unreachable }

class ShellResult {
  const ShellResult(this.exitCode, this.output);
  final int exitCode;
  final String output;
}

/// ADB to the TV over the network, through Adb.kt (dadb). Only the install flow uses it.
class Adb {
  static const _channel = MethodChannel('tv.ilona.companion/adb');

  /// Waits for the TV's "Allow debugging?" prompt; Adb.kt gives up after 60 s.
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
