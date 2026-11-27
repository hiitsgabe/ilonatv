import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';

import '../adb.dart';
import '../i18n.dart';
import '../releases.dart';
import '../tv_client.dart';
import '../tvs.dart';
import 'browse.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({
    super.key,
    required this.tv,
    required this.client,
    required this.tvs,
    this.updates,
    this.onUpdate,
    this.adb,
  });

  final Tv tv;
  final TvClient client;
  final Tvs tvs;
  final UpdateCheck? updates;

  /// For the keys the TV can't reach while another app is in front.
  final Adb? adb;

  /// Opens the installer, which sees the older version and offers Update.
  final VoidCallback? onUpdate;

  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  StreamSubscription<TvInfo>? _sub;
  Timer? _retry;
  TvInfo? _info;
  bool _unreachable = false;
  bool? _notInFront;
  int _fails = 0;
  bool _forgetting = false;
  final _queue = <RemoteKey>[];
  bool _sending = false;
  String? _latest;
  late final Adb _adb = widget.adb ?? Adb();
  bool _adbUsed = false;
  bool _adbUp = false;
  bool _adbBusy = false;
  bool _adbTried = false;
  bool _adbNote = false;
  AdbResult? _adbFail;
  int _adbGen = 0;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    widget.tvs.hold();
    _life = AppLifecycleListener(onPause: _adbPause, onResume: _adbIfKnown);
    widget.updates?.latest.then((v) {
      if (mounted && v != null) setState(() => _latest = v);
    });
    _connect();
  }

  @override
  void dispose() {
    widget.tvs.release();
    _sub?.cancel();
    _retry?.cancel();
    _life.dispose();
    if (_adbUsed) _adb.close();
    super.dispose();
  }

  void _connect() {
    _retry?.cancel();
    _sub?.cancel();
    _sub = widget.client.events().listen((i) {
      if (!mounted) return;
      setState(() {
        _info = i;
        _unreachable = false;
        _fails = 0;
        if (i.inFront) _adbNote = false;
      });
      _adbIfKnown();
    }, onDone: _ended);
  }

  // Only to a TV that allowed this phone before, so no prompt comes up unasked.
  Future<void> _adbIfKnown() async {
    final i = _info;
    if (_adbTried || i == null || i.inFront || i.keysOutside == 'all') return;
    _adbTried = true;
    if (await _adb.knows(widget.tv.host)) await _adbConnect();
  }

  // The phone app went away: no connection held open behind it.
  void _adbPause() {
    _adbGen++;
    if (_adbUsed) _adb.close();
    _adbUsed = false;
    setState(() {
      _adbUp = false;
      _adbBusy = false;
      _adbTried = false;
    });
  }

  Future<void> _adbConnect() async {
    if (_adbBusy || _adbUp || !mounted) return;
    setState(() => _adbBusy = true);
    _adbUsed = true;
    final gen = _adbGen;
    final r = await _adb.connect(widget.tv.host, kAdbPort);
    if (!mounted || gen != _adbGen) return;
    setState(() {
      _adbBusy = false;
      _adbUp = r == AdbResult.ok;
      _adbFail = _adbUp ? null : r;
      if (_adbUp) _adbNote = false;
    });
  }

  Future<bool> _sendAdb(RemoteKey k, {bool note = true}) async {
    if (_adbUp && await _adb.key(k)) return true;
    if (mounted) {
      setState(() {
        _adbUp = false;
        if (note) _adbNote = true;
      });
    }
    return false;
  }

  // events() ends silently on a failed connect, so ask the TV why.
  Future<void> _ended() async {
    final r = await widget.client.info();
    if (!mounted) return;
    switch (r) {
      case Unpaired():
        await _forgotten();
      case Ok(:final value):
        if (++_fails >= 3) {
          setState(() => _unreachable = true);
          return;
        }
        setState(() {
          _info = value;
          _unreachable = false;
        });
        _retry = Timer(const Duration(seconds: 2), _connect);
      default:
        setState(() => _unreachable = true);
    }
  }

  Future<void> _forgotten() async {
    if (_forgetting) return;
    _forgetting = true;
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    await widget.tvs.forget(widget.tv.host);
    messenger.showSnackBar(SnackBar(content: Text(t('removedPairAgain'))));
    if (nav.mounted) nav.popUntil((r) => r.isFirst);
  }

  Future<void> _handle(TvResult r) async {
    if (!mounted) return;
    switch (r) {
      case Unpaired():
        await _forgotten();
      case NotInFront(:final launcherMode):
        setState(() => _notInFront = launcherMode);
      case Unreachable():
        setState(() => _unreachable = true);
      case Ok():
        if (_notInFront != null || _unreachable) {
          setState(() {
            _notInFront = null;
            _unreachable = false;
          });
        }
      default:
    }
  }

  Future<void> _press(RemoteKey k) async {
    HapticFeedback.lightImpact();
    if (_queue.length >= 3) return;
    _queue.add(k);
    if (_sending) return;
    _sending = true;
    while (_queue.isNotEmpty && mounted) {
      final k = _queue.removeAt(0);
      final i = _info;
      final outside = i?.keysOutside;
      // Before the first state event nothing is known: the TV's server first.
      if (i != null &&
          useAdb(k, inFront: i.inFront, keysOutside: outside, adbUp: _adbUp)) {
        // A media key that ADB dropped still has the TV's own way.
        if (await _sendAdb(k, note: !i.inFront) || !mediaKeys.contains(k)) {
          continue;
        }
      }
      final r = await widget.client.key(k);
      // The TV left Ilona TV before its event said so; ADB is the way, so no
      // Open Ilona TV on top of its note.
      if (r is NotInFront &&
          outside != null &&
          useAdb(k, inFront: false, keysOutside: outside, adbUp: _adbUp)) {
        await _sendAdb(k);
        continue;
      }
      await _handle(r);
    }
    _sending = false;
  }

  void _retryNow() {
    _fails = 0;
    setState(() => _unreachable = false);
    _connect();
  }

  @override
  Widget build(BuildContext context) {
    final step = _info?.step;
    final setup = step == 'tmdb' || step == 'location';
    final tvUpdate =
        widget.onUpdate != null &&
        _latest != null &&
        _info != null &&
        isOlder(_info!.version, _latest!);
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.tv.label),
          bottom: TabBar(
            tabs: [
              Tab(text: t('tabRemote')),
              Tab(text: t('tabSearch')),
              Tab(text: t('tabBrowse')),
            ],
          ),
        ),
        body: Column(
          children: [
            if (_unreachable)
              _Banner(
                text: t('cantReachTv').replaceAll('{name}', widget.tv.label),
                action: TextButton(
                  onPressed: _retryNow,
                  child: Text(t('retry')),
                ),
              ),
            if (tvUpdate)
              _Banner(
                text: t('tvUpdate').replaceAll('{version}', _latest!),
                action: TextButton(
                  onPressed: widget.onUpdate,
                  child: Text(t('instUpdate')),
                ),
              ),
            if (_notInFront != null)
              _Banner(
                text: t('notInFront'),
                sub: _notInFront == false ? t('launcherTip') : null,
              ),
            if (_adbNote && !_adbUp)
              _Banner(
                text: t('adbNote'),
                sub: t(
                  _adbFail == AdbResult.unauthorized ? 'adbDenied' : 'adbHow',
                ),
                action: _adbBusy
                    ? const SizedBox.square(
                        dimension: 24,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : TextButton(
                        onPressed: _adbConnect,
                        child: Text(t('adbConnect')),
                      ),
              ),
            Expanded(
              child: TabBarView(
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  LayoutBuilder(
                    builder: (context, c) => Column(
                      children: [
                        if (setup)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxHeight: c.maxHeight > 250
                                  ? c.maxHeight - 250
                                  : 0,
                            ),
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.all(16),
                              child: step == 'tmdb'
                                  ? _TmdbCard(
                                      client: widget.client,
                                      onResult: _handle,
                                    )
                                  : _CityCard(
                                      client: widget.client,
                                      onResult: _handle,
                                    ),
                            ),
                          ),
                        Expanded(child: _Pad(onKey: _press)),
                      ],
                    ),
                  ),
                  SearchTab(client: widget.client, onResult: _handle),
                  BrowseTab(client: widget.client, onResult: _handle),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.sub, this.action});

  final String text;
  final String? sub;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(text, style: const TextStyle(fontWeight: FontWeight.w600)),
                if (sub != null)
                  Text(sub!, style: const TextStyle(fontSize: 13)),
              ],
            ),
          ),
          ?action,
        ],
      ),
    ),
  );
}

class _TmdbCard extends StatefulWidget {
  const _TmdbCard({required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<_TmdbCard> createState() => _TmdbCardState();
}

class _TmdbCardState extends State<_TmdbCard> {
  final _key = TextEditingController();
  String? _message;
  bool _busy = false;
  bool _hidden = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(bool save) async {
    final k = _key.text.trim();
    if (k.isEmpty || _busy) return;
    setState(() => _busy = true);
    final r = await widget.client.setupTmdb(k, save: save);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = switch (r) {
        Ok(value: 'keyOk') when save => t('keySaved'),
        Ok(:final value) => t(value),
        Unreachable() || Refused() => t('networkError'),
        _ => null,
      };
    });
    if (r is! Ok) await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _key,
            autocorrect: false,
            enableSuggestions: false,
            obscureText: _hidden,
            decoration: InputDecoration(
              labelText: t('tmdbKey'),
              suffixIcon: IconButton(
                icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
                onPressed: () => setState(() => _hidden = !_hidden),
              ),
            ),
          ),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_message!),
            ),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _busy ? null : () => _run(false),
                child: Text(t('test')),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _run(true),
                child: Text(t('save')),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

class _CityCard extends StatefulWidget {
  const _CityCard({required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<_CityCard> createState() => _CityCardState();
}

class _CityCardState extends State<_CityCard> {
  final _q = TextEditingController();
  List<Place>? _places;
  bool _busy = false;
  String? _set;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _set = null;
    });
    final r = await widget.client.cities(q);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r is Ok<List<Place>>) {
      setState(() => _places = r.value);
    } else {
      await widget.onResult(r);
    }
  }

  Future<void> _pick(Place p) async {
    final r = await widget.client.setCity(p);
    if (mounted && r is Ok) {
      setState(() {
        _places = null;
        _set = p.name;
      });
    }
    await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _q,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            decoration: InputDecoration(
              labelText: t('city'),
              hintText: t('searchCity'),
              suffixIcon: IconButton(
                icon: const Icon(Icons.search),
                onPressed: _search,
              ),
            ),
          ),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            )
          else if (_places?.isEmpty ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('noResults')),
            )
          else if (_set case final city?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(t('citySet').replaceAll('{city}', city)),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 160),
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final p in _places ?? const <Place>[])
                  ListTile(
                    dense: true,
                    title: Text(p.name),
                    subtitle: Text(
                      [
                        p.region,
                        p.country,
                      ].where((s) => s.isNotEmpty).join(', '),
                    ),
                    onTap: () => _pick(p),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _Pad extends StatefulWidget {
  const _Pad({required this.onKey});

  final void Function(RemoteKey) onKey;

  @override
  State<_Pad> createState() => _PadState();
}

class _PadState extends State<_Pad> {
  static const _swipe = 40.0;
  Offset _drag = Offset.zero;

  void _tap(Offset p, double size) {
    final d = p - Offset(size / 2, size / 2);
    if (d.distance < size * 0.2) {
      HapticFeedback.selectionClick();
      widget.onKey(RemoteKey.ok);
    } else if (d.dx.abs() > d.dy.abs()) {
      widget.onKey(d.dx > 0 ? RemoteKey.right : RemoteKey.left);
    } else {
      widget.onKey(d.dy > 0 ? RemoteKey.down : RemoteKey.up);
    }
  }

  void _pan(Offset delta) {
    _drag += delta;
    if (_drag.distance < _swipe) return;
    final d = _drag;
    _drag = Offset.zero;
    widget.onKey(
      d.dx.abs() > d.dy.abs()
          ? (d.dx > 0 ? RemoteKey.right : RemoteKey.left)
          : (d.dy > 0 ? RemoteKey.down : RemoteKey.up),
    );
  }

  Widget _round(IconData icon, String label, RemoteKey k) => Semantics(
    label: label,
    button: true,
    child: Material(
      color: const Color(0x2EFFFFFF),
      shape: const CircleBorder(side: BorderSide(color: Color(0x66FFFFFF))),
      child: InkResponse(
        key: Key('key-${k.name}'),
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onKey(k);
        },
        child: SizedBox(width: 64, height: 64, child: Icon(icon, size: 28)),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final size =
          (c.maxWidth < c.maxHeight - 130 ? c.maxWidth : c.maxHeight - 130)
              .clamp(120.0, 340.0);
      return Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          GestureDetector(
            key: const Key('pad'),
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => _tap(d.localPosition, size),
            onPanStart: (_) => _drag = Offset.zero,
            onPanUpdate: (d) => _pan(d.delta),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: const Color(0x14FFFFFF),
                border: Border.all(color: const Color(0x66FFFFFF), width: 2),
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  const Align(
                    alignment: Alignment(0, -0.78),
                    child: Icon(Icons.keyboard_arrow_up, size: 40),
                  ),
                  const Align(
                    alignment: Alignment(0, 0.78),
                    child: Icon(Icons.keyboard_arrow_down, size: 40),
                  ),
                  const Align(
                    alignment: Alignment(-0.78, 0),
                    child: Icon(Icons.keyboard_arrow_left, size: 40),
                  ),
                  const Align(
                    alignment: Alignment(0.78, 0),
                    child: Icon(Icons.keyboard_arrow_right, size: 40),
                  ),
                  Container(
                    width: size * 0.36,
                    height: size * 0.36,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white,
                      border: Border.all(color: Colors.white54, width: 3),
                    ),
                    alignment: Alignment.center,
                    child: const Text(
                      'OK',
                      style: TextStyle(
                        color: Colors.black,
                        fontWeight: FontWeight.w700,
                        fontSize: 22,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          // Scaled down rather than overflowing on a narrow phone.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              children: [
                _round(Icons.arrow_back, t('back'), RemoteKey.back),
                const SizedBox(width: 24),
                _round(
                  Icons.volume_down,
                  t('volumeDown'),
                  RemoteKey.volumeDown,
                ),
                const SizedBox(width: 8),
                _round(Icons.volume_off, t('mute'), RemoteKey.mute),
                const SizedBox(width: 8),
                _round(Icons.play_arrow, t('playPause'), RemoteKey.playPause),
                const SizedBox(width: 8),
                _round(Icons.volume_up, t('volumeUp'), RemoteKey.volumeUp),
                const SizedBox(width: 24),
                _round(Icons.home_outlined, t('home'), RemoteKey.home),
              ],
            ),
          ),
          const SizedBox(height: 32),
        ],
      );
    },
  );
}
