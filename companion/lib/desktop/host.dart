import 'dart:io';

import 'package:flutter/foundation.dart';

/// The desktop app: macOS and Windows. Everything else is the Android app,
/// which also covers tests, where the platform is Android by default.
bool get isDesktop =>
    defaultTargetPlatform == TargetPlatform.macOS ||
    defaultTargetPlatform == TargetPlatform.windows;

typedef StartProcess = Future<Process> Function(String exe, List<String> args);

Future<Process> startProcess(String exe, List<String> args) =>
    Process.start(exe, args);

// By full path: a tar or rundll32 earlier on PATH (Git's GNU tar) is not the system's.
String get system32 =>
    '${Platform.environment['SystemRoot'] ?? r'C:\Windows'}\\System32';

/// The command that opens [url] in the browser, the URL its own argument so
/// no shell ever reads it; null for anything but https, as on Android.
(String, List<String>)? openUrlCommand(String url, TargetPlatform os) {
  if (Uri.tryParse(url)?.scheme != 'https') return null;
  return switch (os) {
    TargetPlatform.macOS => ('/usr/bin/open', [url]),
    TargetPlatform.windows => (
      '$system32\\rundll32.exe',
      ['url.dll,FileProtocolHandler', url],
    ),
    _ => null,
  };
}

Future<bool> openUrlOnDesktop(
  String url, {
  StartProcess start = startProcess,
}) async {
  final c = openUrlCommand(url, defaultTargetPlatform);
  if (c == null) return false;
  try {
    final p = await start(c.$1, c.$2);
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    return await p.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// The name the TV lists this computer under.
String desktopName() {
  final n = Platform.localHostname.replaceFirst(RegExp(r'\.local$'), '');
  return n.isEmpty ? 'Computer' : n;
}

/// Where the app keeps what it downloads: platform-tools.
String supportDir() {
  final env = Platform.environment;
  return Platform.isWindows
      ? '${env['LOCALAPPDATA']}\\Ilona TV Companion'
      : '${env['HOME']}/Library/Application Support/tv.ilona.companion';
}
