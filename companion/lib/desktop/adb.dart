import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../adb.dart';
import 'platform_tools.dart';

/// `adb devices`: serial to state (device, unauthorized, offline).
Map<String, String> parseDevices(String out) => {
  for (final m in RegExp(r'^(\S+)\t(\S+)\s*$', multiLine: true).allMatches(out))
    m.group(1)!: m.group(2)!,
};

/// Whether `adb connect` reached nothing; "failed to authenticate" is the
/// TV's prompt still up, which adb keeps waiting on.
bool connectFailed(String out) => RegExp(
  r'^(failed to connect|cannot connect|unable to connect)',
  multiLine: true,
).hasMatch(out);

/// Null when `adb pair` paired, else adb's reason.
String? pairFailure(String out) {
  if (out.contains('Successfully paired')) return null;
  final why = out.trim();
  return why.isEmpty ? 'pairing failed' : why;
}

// adb's own errors, not the TV's command: the device is gone.
final _lost = RegExp(
  r"^(?:adb|error): (?:device '.*' not found|device offline|device unauthorized|no devices|closed|protocol fault)",
  multiLine: true,
);

/// ADB to the TV with the adb binary from [PlatformTools], every command an
/// argument list (never a shell string), every call bounded. The same
/// contract as Adb.kt on Android: one connection, one shell kept open for
/// keys, all of it dropped on [close].
class DesktopAdb implements AdbBackend {
  DesktopAdb({
    PlatformTools? tools,
    Future<bool> Function(String host, int port)? reachable,
    this.poll = const Duration(seconds: 1),
    this.authWait = const Duration(seconds: 60),
    this.shellTimeout = const Duration(seconds: 30),
  }) : tools = tools ?? PlatformTools(),
       _reachable = reachable ?? _tcpOpen;

  final PlatformTools tools;
  final Future<bool> Function(String host, int port) _reachable;
  final Duration poll;

  /// How long the TV's "Allow debugging?" may stay unanswered, as Adb.kt.
  final Duration authWait;
  final Duration shellTimeout;

  String? _serial;
  Process? _keys;
  int _gen = 0;

  @override
  bool get ready => tools.adbPath() != null;

  @override
  Future<void> download({void Function(int got, int total)? progress}) =>
      tools.download(progress: progress);

  Future<ShellResult> _run(List<String> args, {Duration? timeout}) async {
    final exe = tools.adbPath();
    if (exe == null) return const ShellResult(-1, 'no adb');
    final Process p;
    try {
      p = await tools.start(exe, args);
    } on ProcessException catch (e) {
      return ShellResult(-1, e.message);
    }
    final out = BytesBuilder(copy: false);
    final subs = [p.stdout.listen(out.add), p.stderr.listen(out.add)];
    final drained = Future.wait(subs.map((s) => s.asFuture<void>()));
    var code = await p.exitCode.timeout(
      timeout ?? shellTimeout,
      onTimeout: () {
        p.kill();
        return -1;
      },
    );
    // The adb server the first command forks can hold the pipes open: exit, not the streams' end, is done.
    await drained.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () => const [],
    );
    for (final s in subs) {
      s.cancel();
    }
    final text = utf8.decode(out.takeBytes(), allowMalformed: true);
    if (code != 0 && _lost.hasMatch(text)) code = -1;
    return ShellResult(code, text);
  }

  @override
  Future<AdbResult> connect(String host, int port) async {
    final g = _gen;
    if (!ready || !await _reachable(host, port)) return AdbResult.unreachable;
    final serial = '$host:$port';
    final r = await _run([
      'connect',
      serial,
    ], timeout: const Duration(seconds: 15));
    if (r.exitCode == -1 || connectFailed(r.output)) {
      return AdbResult.unreachable;
    }
    final until = DateTime.now().add(authWait);
    while (g == _gen) {
      final d = await _run(['devices']);
      if (parseDevices(d.output)[serial] == 'device') {
        if (g != _gen) break;
        if (_serial != serial) {
          _keys?.kill();
          _keys = null;
        }
        _serial = serial;
        return AdbResult.ok;
      }
      if (DateTime.now().isAfter(until)) break;
      await Future<void>.delayed(poll);
    }
    return AdbResult.unauthorized;
  }

  @override
  Future<String?> pair(String host, int port, String code) async {
    if (!RegExp(r'^\d{6}$').hasMatch(code)) return 'bad code';
    final r = await _run(['pair', '$host:$port', code]);
    return r.exitCode == -1 ? r.output.trim() : pairFailure(r.output);
  }

  @override
  Future<ShellResult> shell(String cmd) async {
    final s = _serial;
    if (s == null) return const ShellResult(-1, 'not connected');
    return _run(['-s', s, 'shell', cmd]);
  }

  // Android's keycodes are well under 1000; anything else is not a key.
  @override
  Future<bool> key(int code) async {
    if (code < 0 || code > 999) return false;
    for (var attempt = 0; attempt < 2; attempt++) {
      final shell = _keys ?? await _openKeys();
      if (shell == null) return false;
      try {
        shell.stdin.write('input keyevent $code\n');
        await shell.stdin.flush().timeout(const Duration(seconds: 3));
        return true;
      } catch (_) {
        if (_keys == shell) _keys = null;
        shell.kill();
      }
    }
    return false;
  }

  // One shell for every key, its output dropped so nothing waits on a reader.
  Future<Process?> _openKeys() async {
    final s = _serial, exe = tools.adbPath();
    if (s == null || exe == null) return null;
    final Process p;
    try {
      p = await tools.start(exe, ['-s', s, 'shell']);
    } on ProcessException {
      return null;
    }
    p.stdout.drain<void>();
    p.stderr.drain<void>();
    p.stdin.done.catchError((_) {});
    p.exitCode.then((_) {
      if (_keys == p) _keys = null;
    });
    p.stdin.write('exec >/dev/null 2>&1\n');
    return _keys = p;
  }

  @override
  Future<String?> install(String path) async {
    final s = _serial;
    if (s == null) return 'not connected';
    final r = await _run([
      '-s',
      s,
      'install',
      '-r',
      path,
    ], timeout: const Duration(minutes: 3));
    if (r.exitCode == 0 && r.output.contains('Success')) return null;
    return r.output.trim().isEmpty ? 'exit ${r.exitCode}' : r.output.trim();
  }

  @override
  Future<void> close() async {
    _gen++;
    _keys?.kill();
    _keys = null;
    final s = _serial;
    _serial = null;
    if (s != null) {
      await _run(['disconnect', s], timeout: const Duration(seconds: 5));
    }
  }
}

Future<bool> _tcpOpen(String host, int port) async {
  try {
    final s = await Socket.connect(
      host,
      port,
      timeout: const Duration(seconds: 5),
    );
    s.destroy();
    return true;
  } on SocketException {
    return false;
  }
}
