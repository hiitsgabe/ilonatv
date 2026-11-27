import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// Stands in for dart:io processes: records every command as a list and
/// answers from [reply], so nothing is ever run.
class FakeProcesses {
  final started = <List<String>>[];
  final live = <FakeProcess>[];
  int exitCode = 0;

  /// The answer for a command (exe dropped): its exit code and output; null
  /// is [exitCode] and no output.
  (int, String)? Function(List<String> args) reply = (_) => null;

  /// A command that never exits by itself.
  bool Function(List<String> args) hangs = (_) => false;

  Future<Process> start(String exe, List<String> args) async {
    started.add([exe, ...args]);
    final r = reply(args) ?? (exitCode, '');
    final p = FakeProcess(r.$2, hangs(args) ? null : r.$1);
    live.add(p);
    return p;
  }
}

class FakeProcess implements Process {
  FakeProcess(String output, int? code) {
    _out.add(utf8.encode(output));
    _out.close();
    _err.close();
    if (code != null) _exit.complete(code);
    stdin = IOSink(_StdinSink(this));
  }

  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  final written = <String>[];
  bool killed = false;
  bool brokenPipe = false;

  @override
  late final IOSink stdin;

  @override
  Stream<List<int>> get stdout => _out.stream;

  @override
  Stream<List<int>> get stderr => _err.stream;

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => 1;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(-9);
    return true;
  }

  /// The process ends by itself, like adb's shell after the TV dropped it.
  void die() {
    brokenPipe = true;
    if (!_exit.isCompleted) _exit.complete(255);
  }
}

class _StdinSink implements StreamConsumer<List<int>> {
  _StdinSink(this.p);
  final FakeProcess p;

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      if (p.brokenPipe) throw const SocketException('Broken pipe');
      p.written.add(utf8.decode(chunk));
    }
  }

  @override
  Future<void> close() async {}
}
