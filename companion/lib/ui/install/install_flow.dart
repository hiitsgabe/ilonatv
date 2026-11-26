import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';

import '../../adb.dart';
import '../../i18n.dart';
import '../../tv_client.dart';
import '../../tvs.dart';
import '../pair_page.dart';
import '../remote_page.dart';
import 'scan.dart';

const readmeUrl = 'https://github.com/hiitsgabe/ilonatv#get-started';
const _pkg = 'tv.ilona.app';
const _adbPort = 5555;
const _steps = 9;

enum _Kind { fireTv, androidTv, googleTv }

String? pickAbi(String abilist) {
  final abis = abilist.trim().split(',');
  for (final a in ['arm64-v8a', 'armeabi-v7a']) {
    if (abis.contains(a)) return a;
  }
  return null;
}

class InstallFlow extends StatefulWidget {
  const InstallFlow({
    super.key,
    required this.adb,
    required this.tvs,
    required this.assets,
    required this.clientFor,
    this.scan = scanSubnet,
  });

  final Adb adb;
  final Tvs tvs;
  final AssetBundle assets;
  final ClientFor clientFor;
  final Stream<String> Function() scan;

  @override
  State<InstallFlow> createState() => _InstallFlowState();
}

class _InstallFlowState extends State<InstallFlow> {
  final _ip = TextEditingController();
  int _step = 0;
  _Kind? _kind;
  String _host = '';
  int _port = _adbPort;
  bool _busy = false;
  String? _error;
  bool _canRetry = false;
  int _sdk = 0;
  String? _abi;
  bool _update = false;
  List<String> _missed = const [];
  final _hits = <String>[];
  StreamSubscription<String>? _scan;
  // Bumped on Back and on each new run, so a run that was left behind stops touching the screen.
  int _gen = 0;

  Adb get _adb => widget.adb;

  @override
  void initState() {
    super.initState();
    widget.tvs.hold();
  }

  @override
  void dispose() {
    widget.tvs.release();
    _gen++;
    _scan?.cancel();
    _ip.dispose();
    _adb.close();
    super.dispose();
  }

  bool _stale(int g) => g != _gen || !mounted;

  void _show(int step) => setState(() {
    _step = step;
    _busy = true;
    _error = null;
    _canRetry = false;
  });

  void _fail(String error, {bool retry = true}) => setState(() {
    _busy = false;
    _error = error;
    _canRetry = retry;
  });

  // dadb's shell and install have no bound of their own; a TV that drops off Wi-Fi would block forever.
  Future<ShellResult> _sh(String cmd) {
    final g = _gen;
    return _adb
        .shell(cmd)
        .timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            // A run left with Back must not close the connection a newer run opened.
            if (g == _gen) _adb.close();
            return const ShellResult(-1, 'timeout');
          },
        );
  }

  void _back() {
    _gen++;
    if (_step == 0 || _step == 8) {
      Navigator.of(context).pop();
      return;
    }
    if (_step >= 3) _adb.close();
    _scan?.cancel();
    setState(() {
      _step = _step >= 3 ? 2 : _step - 1;
      _busy = false;
      _error = null;
      _canRetry = false;
    });
    if (_step == 2) _startScan();
  }

  void _choose(_Kind k) => setState(() {
    _kind = k;
    _step = 1;
  });

  void _toFind() {
    setState(() => _step = 2);
    _startScan();
  }

  void _startScan() {
    _scan?.cancel();
    setState(() {
      _hits.clear();
      _busy = true;
    });
    _scan = widget.scan().listen(
      (h) => setState(() => _hits.add(h)),
      onError: (Object _) {
        if (mounted) setState(() => _busy = false);
      },
      onDone: () {
        if (mounted) setState(() => _busy = false);
      },
    );
  }

  void _typed() {
    final h = parseHostInput(_ip.text);
    if (h == null) {
      setState(() {
        _error = t('badAddress');
        _canRetry = false;
      });
      return;
    }
    _pick(h.host, h.port ?? _adbPort);
  }

  void _pick(String host, [int port = _adbPort]) {
    _scan?.cancel();
    _host = host;
    _port = port;
    _connect();
  }

  Future<void> _connect() async {
    final g = ++_gen;
    _show(3);
    // A denied or ignored prompt leaves an attempt that a new connect would reuse; close drops it.
    await _adb.close();
    if (_stale(g)) return;
    final r = await _adb.connect(_host, _port);
    if (_stale(g)) return;
    if (r == AdbResult.ok) return _check(g);
    _fail(_whyNot(r));
  }

  String _whyNot(AdbResult r) => r == AdbResult.unauthorized
      ? t('instNotAllowed')
      : t('instNoAdb').replaceAll('{host}', '$_host:$_port');

  Future<void> _retry() async {
    final step = _step;
    if (step == 3) return _connect();
    if (step < 4 || step > 7) return;
    final g = ++_gen;
    _show(step);
    await _adb.close();
    if (_stale(g)) return;
    final r = await _adb.connect(_host, _port);
    if (_stale(g)) return;
    if (r != AdbResult.ok) {
      _show(3);
      return _fail(_whyNot(r));
    }
    switch (step) {
      case 4:
        return _check(g);
      case 5:
        return _install(g);
      case 6:
        return _perms(g);
      case 7:
        return _pair(g);
    }
  }

  Future<void> _check(int g) async {
    _show(4);
    final out = <String>[];
    for (final cmd in [
      'getprop ro.build.version.sdk',
      'getprop ro.product.cpu.abilist',
      'pm list packages $_pkg',
    ]) {
      final r = await _sh(cmd);
      if (_stale(g)) return;
      // A failed call means the connection is gone; another call would let dadb reconnect with no bound.
      if (r.exitCode == -1) return _fail(t('instAdbLost'));
      out.add(r.output);
    }
    final [sdk, abis, pkgs] = out;
    _sdk = int.tryParse(sdk.trim()) ?? 0;
    _abi = pickAbi(abis);
    if (_abi == null) {
      return _fail(
        t('instBadCpu').replaceAll('{abi}', abis.trim()),
        retry: false,
      );
    }
    _update = pkgs.split('\n').any((l) => l.trim() == 'package:$_pkg');
    setState(() => _busy = false);
  }

  Future<void> _install(int g) async {
    _show(5);
    final name = 'ilonatv-$_abi.apk';
    final ByteData data;
    try {
      data = await widget.assets.load('assets/tv/$name');
    } catch (_) {
      if (_stale(g)) return;
      return _fail(t('instNoApk').replaceAll('{abi}', _abi!), retry: false);
    }
    if (_stale(g)) return;
    final file = File('${Directory.systemTemp.path}/$name');
    try {
      // shortcut: a sync write blocks the UI for the APK's size (tens of MB, well under a second); go async if it janks.
      file.writeAsBytesSync(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    } on FileSystemException {
      if (_stale(g)) return;
      return _fail(t('instNoSpace'));
    }
    if (_stale(g)) return;
    var timedOut = false;
    final err = await _adb
        .install(file.path)
        .timeout(
          const Duration(minutes: 3),
          onTimeout: () {
            timedOut = true;
            if (!_stale(g)) _adb.close();
            return '';
          },
        );
    try {
      file.deleteSync();
    } on FileSystemException {
      // the cache is cleared by the system anyway
    }
    if (_stale(g)) return;
    if (timedOut) return _fail(t('instTooLong'));
    if (err != null) return _fail(t('instFailed').replaceAll('{why}', err));
    return _perms(g);
  }

  Future<void> _perms(int g) async {
    _show(6);
    final cmds = {
      for (final p in ['WRITE_SECURE_SETTINGS', 'DUMP', 'PACKAGE_USAGE_STATS'])
        p: 'pm grant $_pkg android.permission.$p',
      if (_sdk >= 33)
        'ACCESS_RESTRICTED_SETTINGS':
            'appops set $_pkg ACCESS_RESTRICTED_SETTINGS allow',
    };
    final missed = <String>[];
    for (final MapEntry(:key, :value) in cmds.entries) {
      final r = await _sh(value);
      if (_stale(g)) return;
      if (r.exitCode == -1) return _fail(t('instAdbLost'));
      if (r.exitCode != 0 || r.output.trim().isNotEmpty) missed.add(key);
    }
    _missed = missed;
    return _pair(g);
  }

  Future<void> _pair(int g) async {
    _show(7);
    final start = await _sh('am start -n $_pkg/.MainActivity');
    if (_stale(g)) return;
    if (start.exitCode == -1) return _fail(t('instAdbLost'));
    final client = widget.clientFor(
      Tv(host: _host, port: kCompanionPort, name: _host),
    );
    var up = false;
    // About a second per try, so 15 tries is the 15 s the TV app gets to start its server.
    for (var i = 0; i < 15 && !up; i++) {
      final (r, _) = await (
        client.info().timeout(
          const Duration(seconds: 1),
          onTimeout: () => const Unreachable('timeout'),
        ),
        Future<void>.delayed(const Duration(seconds: 1)),
      ).wait;
      if (_stale(g)) return;
      up = r is! Unreachable;
    }
    if (!up) return _fail(t('instNotStarted'));
    final q = await _sh('content query --uri content://$_pkg.pairing/secret');
    if (_stale(g)) return;
    if (q.exitCode == -1) return _fail(t('instAdbLost'));
    final secret = RegExp(r'secret=([0-9a-f]{32})').firstMatch(q.output);
    if (secret == null) return _fail(t('instNoSecret'));
    final r = await client.pair(
      secret: secret.group(1),
      name: await deviceName(),
    );
    if (_stale(g)) return;
    if (r is! Ok<String>) return _fail(t('instPairFailed'));
    await widget.tvs.savePaired(
      Tv(host: _host, port: kCompanionPort, name: 'IlonaTv'),
      r.value,
    );
    if (_stale(g)) return;
    setState(() {
      _step = 8;
      _busy = false;
    });
  }

  Future<void> _openRemote() async {
    await _adb.close();
    if (!mounted) return;
    final tv = widget.tvs.all.firstWhere((t) => t.host == _host);
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) =>
            RemotePage(tv: tv, client: widget.clientFor(tv), tvs: widget.tvs),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final titles = [
      'instWhichTv',
      'instDebugTitle',
      'instFindTitle',
      'instConnectTitle',
      'instCheckTitle',
      'instInstallTitle',
      'instPermsTitle',
      'instPairTitle',
      'instDoneTitle',
    ];
    final (body, action) = _content();
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: BackButton(onPressed: _back),
          title: Text(t('instStepOf').replaceAll('{n}', '${_step + 1}')),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_step + 1) / _steps,
              backgroundColor: const Color(0x14FFFFFF),
            ),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  t(titles[_step]),
                  style: const TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 20),
                Expanded(
                  child: ListView(
                    children: [...body, if (_error != null) _Error(_error!)],
                  ),
                ),
                if (_error != null && _canRetry)
                  _Primary(t('retry'), _retry)
                else
                  ?action,
              ],
            ),
          ),
        ),
      ),
    );
  }

  (List<Widget>, Widget?) _content() {
    final working = _busy && _error == null;
    switch (_step) {
      case 0:
        return (
          [
            for (final (k, key, icon) in [
              (_Kind.fireTv, 'instFireTv', Icons.tv),
              (_Kind.androidTv, 'instAndroidTv', Icons.connected_tv),
              (_Kind.googleTv, 'instGoogleTv', Icons.live_tv),
            ])
              _Choice(t(key), icon, () => _choose(k)),
          ],
          null,
        );
      case 1:
        if (_kind == _Kind.googleTv) {
          return (
            [
              _Note(t('instUseComputer'), big: true),
              _Note(t('instNeeds5555')),
              const SizedBox(height: 8),
              SelectableText(
                readmeUrl,
                style: const TextStyle(color: Color(0xB3FFFFFF)),
              ),
            ],
            _Primary(t('instOpenReadme'), () => openUrl(readmeUrl)),
          );
        }
        final keys = _kind == _Kind.fireTv
            ? ['instFire1', 'instFire2', 'instFire3']
            : ['instAndroid1', 'instAndroid2', 'instAndroid3'];
        return (
          [
            for (final (i, k) in keys.indexed)
              InstallStepCard(number: i + 1, text: t(k)),
          ],
          _Primary(t('next'), _toFind),
        );
      case 2:
        return (
          [
            if (_busy) ...[
              _Note(t('instScanning')),
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ] else if (_hits.isEmpty)
              _Note(t('instNoneFound')),
            for (final h in _hits) _Choice(h, Icons.tv, () => _pick(h)),
            if (!_busy)
              TextButton(
                onPressed: _startScan,
                child: Text(t('instScanAgain')),
              ),
            const SizedBox(height: 12),
            TextField(
              controller: _ip,
              keyboardType: TextInputType.url,
              decoration: _field(t('instTypeIp')),
              onSubmitted: (_) => _typed(),
            ),
          ],
          _Primary(t('instConnect'), _typed),
        );
      case 3:
        return (
          [_Note(t('instAllow'), big: true), if (working) _spinner],
          null,
        );
      case 4:
        if (working) return ([_Note(t('instChecking')), _spinner], null);
        if (_error != null) return (const [], null);
        return (
          [
            _Note(
              t('instTvSummary')
                  .replaceAll('{sdk}', '$_sdk')
                  .replaceAll('{abi}', _abi!),
            ),
            _Note(t(_update ? 'instExisting' : 'instFresh'), big: true),
          ],
          _Primary(
            t(_update ? 'instUpdate' : 'instInstall'),
            () => _install(++_gen),
          ),
        );
      case 5:
        return (
          [
            _Note(t('instInstalling')),
            if (working) const LinearProgressIndicator(),
          ],
          null,
        );
      case 6:
        return ([_Note(t('instGranting')), if (working) _spinner], null);
      case 7:
        return ([_Note(t('instStarting')), if (working) _spinner], null);
      default:
        return (
          [
            _Note(t('instDone'), big: true),
            if (_missed.isNotEmpty)
              _Note(
                t('instPermsMissed').replaceAll('{list}', _missed.join(', ')),
              ),
          ],
          _Primary(t('instOpenRemote'), _openRemote),
        );
    }
  }

  static const _spinner = Padding(
    padding: EdgeInsets.all(24),
    child: Center(child: CircularProgressIndicator()),
  );

  InputDecoration _field(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: const Color(0x14FFFFFF),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0x66FFFFFF)),
    ),
  );
}

/// A numbered step; [image] is for the screenshots in assets/install/*.webp once they exist.
class InstallStepCard extends StatelessWidget {
  const InstallStepCard({
    super.key,
    required this.number,
    required this.text,
    this.image,
  });

  final int number;
  final String text;
  final String? image;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (image != null) Image.asset(image!, fit: BoxFit.cover),
        Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                child: Text(
                  '$number',
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 16, height: 1.4),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _Choice extends StatelessWidget {
  const _Choice(this.label, this.icon, this.onTap);

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 12),
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          children: [
            Icon(icon, size: 30),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}

class _Note extends StatelessWidget {
  const _Note(this.text, {this.big = false});

  final String text;
  final bool big;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Text(
      text,
      style: TextStyle(
        fontSize: big ? 20 : 16,
        height: 1.4,
        fontWeight: big ? FontWeight.w600 : FontWeight.w400,
      ),
    ),
  );
}

class _Error extends StatelessWidget {
  const _Error(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 16, color: Color(0xFFFF8A80)),
    ),
  );
}

class _Primary extends StatelessWidget {
  const _Primary(this.label, this.onPressed);

  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(60),
      textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    child: Text(label),
  );
}
