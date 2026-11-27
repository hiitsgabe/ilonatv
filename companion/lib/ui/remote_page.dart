import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';

import '../adb.dart';
import '../desktop/host.dart';
import '../i18n.dart';

import 'package:ilonatv_protocol/releases.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tv_client.dart';
import '../tvs.dart';
import 'adb_tools.dart';
import 'browse.dart';
import 'device_sheet.dart';
import 'keyboard_sheet.dart';
import 'pair_page.dart';
import 'theme.dart';

class RemotePage extends StatefulWidget {
  const RemotePage({
    super.key,
    required this.tv,
    required this.client,
    required this.tvs,
    this.updates,
    this.onUpdate,
    this.adb,
    this.clientFor,
  });

  /// For the device picker's other TVs.
  final ClientFor? clientFor;

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
  int _tab = 0;
  bool _explored = false;
  bool _swipe = false;
  bool _haptics = true;
  bool _volumeKeys = false;
  final _step = ValueNotifier<String?>(null);
  void _rocker(bool up) =>
      _press(up ? RemoteKey.volumeUp : RemoteKey.volumeDown, repeat: true);

  // A remote that replaced this one (another TV) holds the rocker now.
  bool get _ownsRocker => widget.tvs.onVolumeKey == _rocker;

  @override
  void initState() {
    super.initState();
    widget.tvs.hold();
    widget.tvs.onVolumeKey = _rocker;
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _swipe = p.getString(_modePref) == 'swipe';
        _haptics = p.getBool(_hapticsPref) ?? true;
      });
    });
    // A desktop window is hidden (minimised), never paused.
    _life = AppLifecycleListener(
      onPause: _adbPause,
      onResume: _adbIfKnown,
      onHide: isDesktop ? _adbPause : null,
      onShow: isDesktop ? _adbIfKnown : null,
    );
    widget.updates?.latest.then((v) {
      if (mounted && v != null) setState(() => _latest = v);
    });
    _connect();
  }

  @override
  void dispose() {
    if (_ownsRocker) {
      if (_volumeKeys) hardwareVolume(false);
      widget.tvs.onVolumeKey = null;
    }
    widget.tvs.release();
    _step.dispose();
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
      if (i.accent case final a?) accent.value = Color(a);
      final asks = isSetupStep(i.step) && i.step != _info?.step;
      setState(() {
        _info = i;
        _unreachable = false;
        _fails = 0;
        if (i.inFront) _adbNote = false;
        if (!_exploreOk) _tab = 0;
      });
      _step.value = i.step;
      if (asks && (ModalRoute.of(context)?.isCurrent ?? false)) _keyboard();
      _adbIfKnown();
    }, onDone: _ended);
  }

  // Only to a TV that allowed this phone before, so no prompt comes up unasked.
  Future<void> _adbIfKnown() async {
    final i = _info;
    if (_adbTried || i == null || i.inFront || i.keysOutside == 'all') return;
    _adbTried = true;
    if (await _adb.knows(widget.tv.host) && _adb.ready) await _adbConnect();
  }

  Future<void> _adbAsk() async {
    if (await ensureAdbTools(context, _adb)) await _adbConnect();
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
        if (++_fails >= 3) return _down();
        setState(() {
          _info = value;
          _unreachable = false;
        });
        _retry = Timer(const Duration(seconds: 2), _connect);
      default:
        _down();
    }
  }

  // Quietly, until the TV answers; the first state event clears the strip.
  void _down() {
    setState(() => _unreachable = true);
    _retry = Timer(const Duration(seconds: 15), _connect);
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

  /// A [repeat] (a held arrow, the rocker) waits for the queue to empty, so
  /// keys never pile up behind a slow TV and run on after the finger lifts.
  Future<void> _press(RemoteKey k, {bool repeat = false}) async {
    if (_queue.length >= 3 || (repeat && _queue.isNotEmpty)) return;
    if (_haptics && !isDesktop) {
      k == RemoteKey.ok || k == RemoteKey.playPause
          ? HapticFeedback.lightImpact()
          : HapticFeedback.selectionClick();
    }
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

  // The computer's keyboard as the remote's pad.
  KeyEventResult _keyEvent(FocusNode _, KeyEvent e) {
    if (e is KeyUpEvent || _tab != 0) return KeyEventResult.ignored;
    final k = switch (e.logicalKey) {
      LogicalKeyboardKey.arrowUp => RemoteKey.up,
      LogicalKeyboardKey.arrowDown => RemoteKey.down,
      LogicalKeyboardKey.arrowLeft => RemoteKey.left,
      LogicalKeyboardKey.arrowRight => RemoteKey.right,
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter => RemoteKey.ok,
      LogicalKeyboardKey.escape ||
      LogicalKeyboardKey.backspace => RemoteKey.back,
      _ => null,
    };
    if (k == null) return KeyEventResult.ignored;
    _press(k, repeat: e is KeyRepeatEvent);
    return KeyEventResult.handled;
  }

  void _retryNow() {
    _fails = 0;
    setState(() => _unreachable = false);
    _connect();
  }

  static const _modePref = 'remoteMode';
  static const _hapticsPref = 'haptics';

  // Browsing works with another app in front; opening a title needs Ilona TV
  // in front, or Launcher mode.
  bool get _exploreOk {
    final i = _info;
    return i == null || i.inFront || i.launcherMode;
  }

  // A TV older than keysOutside has no media keys of its own.
  bool get _media => _info == null || _info!.keysOutside != null || _adbUp;

  Future<void> _setMode(bool swipe) async {
    setState(() => _swipe = swipe);
    await (await SharedPreferences.getInstance()).setString(
      _modePref,
      swipe ? 'swipe' : 'buttons',
    );
  }

  Future<void> _setHaptics(bool on) async {
    setState(() => _haptics = on);
    await (await SharedPreferences.getInstance()).setBool(_hapticsPref, on);
  }

  void _keyboard() => showKeyboardSheet(
    context,
    client: widget.client,
    step: _step,
    onResult: _handle,
  );

  Future<void> _devices() async {
    final cs = Theme.of(context).colorScheme;
    final nav = Navigator.of(context);
    final clientFor = widget.clientFor;
    final r = await showDeviceSheet(
      context,
      tvs: widget.tvs,
      current: widget.tv,
      currentDot: _dot(cs),
      canSwitch: clientFor != null,
    );
    if (!mounted || r == null) return;
    if (r == DeviceChoice.forget) {
      final sure = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(t('forgetAsk').replaceAll('{name}', widget.tv.label)),
          content: Text(t('forgetWhy')),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(c).pop(false),
              child: Text(t('cancel')),
            ),
            TextButton(
              key: const Key('forgetYes'),
              onPressed: () => Navigator.of(c).pop(true),
              child: Text(t('forget')),
            ),
          ],
        ),
      );
      if (sure != true || !mounted) return;
      await widget.tvs.forget(widget.tv.host);
      if (nav.mounted) nav.popUntil((r) => r.isFirst);
    } else if (r == DeviceChoice.add && clientFor != null) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => PairPage(tvs: widget.tvs, clientFor: clientFor),
        ),
      );
    } else if (r is Tv && r.host != widget.tv.host && clientFor != null) {
      nav.pushReplacement(
        MaterialPageRoute(
          builder: (_) => RemotePage(
            tv: r,
            client: clientFor(r),
            tvs: widget.tvs,
            updates: widget.updates,
            onUpdate: widget.onUpdate,
            clientFor: clientFor,
          ),
        ),
      );
    }
  }

  Color _dot(ColorScheme cs) => _unreachable
      ? cs.error
      : _info != null
      ? Tones.ok
      : cs.onSurfaceVariant;

  Widget? _strip() {
    final i = _info;
    if (_unreachable) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Strip(
            kind: StripKind.error,
            icon: Icons.wifi_off,
            text: t('cantReachTv').replaceAll('{name}', widget.tv.label),
            sub: t('cantReachHint'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _retryNow,
            icon: const Icon(Icons.refresh),
            label: Text(t('retry')),
          ),
        ],
      );
    }
    if (_adbNote && !_adbUp) {
      return Strip(
        kind: StripKind.warn,
        icon: Icons.developer_mode,
        text: t('adbNote'),
        sub: t(_adbFail == AdbResult.unauthorized ? 'adbDenied' : 'adbHow'),
        action: _adbBusy
            ? const Padding(
                padding: EdgeInsets.all(8),
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              )
            : TextButton(onPressed: _adbAsk, child: Text(t('adbConnect'))),
      );
    }
    if (_notInFront != null) {
      return Strip(
        kind: StripKind.warn,
        icon: Icons.open_in_new,
        text: t('notInFront'),
        sub: _notInFront == false ? t('launcherTip') : null,
      );
    }
    if (isSetupStep(i?.step)) {
      return Strip(
        kind: StripKind.info,
        icon: Icons.keyboard_outlined,
        text: t(i!.step == 'tmdb' ? 'tvAsksTmdb' : 'tvAsksCity'),
        action: TextButton(onPressed: _keyboard, child: Text(t('type'))),
      );
    }
    if (i != null && !i.inFront) {
      return Strip(
        kind: StripKind.info,
        icon: Icons.info_outline,
        text: t(_exploreOk ? 'otherAppInFrontLauncher' : 'otherAppInFront'),
      );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tvUpdate =
        widget.onUpdate != null &&
        _latest != null &&
        _info != null &&
        isOlder(_info!.version, _latest!);
    // Only while the remote is what's on screen: a sheet or a page over it
    // gives the rocker back to the phone.
    final current = ModalRoute.of(context)?.isCurrent ?? false;
    // Back on top after a remote pushed over this one (Add TV) is gone.
    if (current) widget.tvs.onVolumeKey = _rocker;
    final volumeKeys =
        current && _info != null && !_unreachable && _media && _tab == 0;
    if (!_ownsRocker) {
      _volumeKeys = false;
    } else if (volumeKeys != _volumeKeys) {
      _volumeKeys = volumeKeys;
      hardwareVolume(volumeKeys);
    }
    final strip = _strip();
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Material(
            color: cs.surfaceContainerHigh,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('device'),
              onTap: _devices,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    StatusDot(_dot(cs)),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        widget.tv.label,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const Icon(Icons.expand_more, size: 20),
                  ],
                ),
              ),
            ),
          ),
        ),
        actions: [
          if (tvUpdate)
            Tooltip(
              message: t('tvUpdate').replaceAll('{version}', _latest!),
              child: ActionChip(
                key: const Key('tvUpdate'),
                onPressed: widget.onUpdate,
                avatar: Icon(
                  Icons.arrow_upward,
                  size: 16,
                  color: cs.onPrimaryContainer,
                ),
                label: Text(
                  t('tvUpdatePill').replaceAll('{version}', _latest!),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: cs.onPrimaryContainer,
                  ),
                ),
                backgroundColor: cs.primaryContainer,
                side: BorderSide.none,
                shape: const StadiumBorder(),
                visualDensity: VisualDensity.compact,
              ),
            ),
          PopupMenuButton<String>(
            key: const Key('more'),
            onSelected: (v) => switch (v) {
              'buttons' => _setMode(false),
              'swipe' => _setMode(true),
              _ => _setHaptics(!_haptics),
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem(
                value: 'buttons',
                checked: !_swipe,
                child: Text(t('buttonsMode')),
              ),
              CheckedPopupMenuItem(
                value: 'swipe',
                checked: _swipe,
                child: Text(t('swipeMode')),
              ),
              if (!isDesktop) ...[
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'haptics',
                  checked: _haptics,
                  child: Text(t('vibration')),
                ),
              ],
            ],
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (strip != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                child: strip,
              ),
            Expanded(
              child: IndexedStack(
                index: _tab,
                children: [
                  Focus(
                    autofocus: isDesktop,
                    onKeyEvent: isDesktop ? _keyEvent : null,
                    child: _Controls(
                      dim: _unreachable,
                      swipe: _swipe,
                      media: _media,
                      onKey: _press,
                      onKeyboard: _keyboard,
                    ),
                  ),
                  if (_explored)
                    ExploreTab(
                      client: widget.client,
                      onResult: _handle,
                      tvLabel: widget.tv.label,
                      onWatched: () {
                        if (mounted) setState(() => _tab = 0);
                      },
                    )
                  else
                    const SizedBox.shrink(),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() {
          _tab = i;
          if (i == 1) _explored = true;
        }),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.settings_remote_outlined),
            selectedIcon: const Icon(Icons.settings_remote),
            label: t('tabRemote'),
          ),
          NavigationDestination(
            icon: const Icon(Icons.grid_view_outlined),
            selectedIcon: const Icon(Icons.grid_view),
            label: t('tabExplore'),
            enabled: _exploreOk,
          ),
        ],
      ),
    );
  }
}

typedef OnKey = void Function(RemoteKey k, {bool repeat});

class _Controls extends StatelessWidget {
  const _Controls({
    required this.dim,
    required this.swipe,
    required this.media,
    required this.onKey,
    required this.onKeyboard,
  });

  final bool dim;
  final bool swipe;
  final bool media;
  final OnKey onKey;
  final VoidCallback onKeyboard;

  @override
  Widget build(BuildContext context) => AnimatedOpacity(
    // Dimmed, not disabled: a press is also how a reachable TV comes back.
    opacity: dim ? 0.35 : 1,
    duration: const Duration(milliseconds: 200),
    child: Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        children: [
          Expanded(
            child: swipe
                ? _TouchPad(onKey: onKey)
                : LayoutBuilder(
                    builder: (context, c) {
                      final w = c.maxWidth * 0.78;
                      final size = (w < c.maxHeight ? w : c.maxHeight).clamp(
                        0.0,
                        320.0,
                      );
                      return Center(
                        child: _DPad(size: size, onKey: onKey),
                      );
                    },
                  ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _RoundKey(
                Icons.arrow_back,
                t('back'),
                const Key('key-back'),
                () => onKey(RemoteKey.back),
              ),
              _RoundKey(
                Icons.home_outlined,
                t('home'),
                const Key('key-home'),
                () => onKey(RemoteKey.home),
              ),
              _RoundKey(
                Icons.keyboard_outlined,
                t('keyboard'),
                const Key('key-keyboard'),
                onKeyboard,
              ),
            ],
          ),
          if (media) ...[const SizedBox(height: 16), _Media(onKey: onKey)],
        ],
      ),
    ),
  );
}

class _RoundKey extends StatelessWidget {
  const _RoundKey(this.icon, this.label, this.keyId, this.onTap);

  final IconData icon;
  final String label;
  final Key keyId;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final fg = onTap == null ? cs.onSurface.withValues(alpha: 0.38) : null;
    return Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: cs.surfaceContainerHigh,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: keyId,
              onTap: onTap,
              child: SizedBox.square(
                dimension: 56,
                child: Icon(icon, color: fg),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Media extends StatelessWidget {
  const _Media({required this.onKey});

  final OnKey onKey;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget part(IconData icon, String label, RemoteKey k) => Semantics(
      label: label,
      button: true,
      excludeSemantics: true,
      child: InkWell(
        key: Key('key-${k.name}'),
        customBorder: const CircleBorder(),
        onTap: () => onKey(k),
        child: SizedBox.square(dimension: 52, child: Icon(icon)),
      ),
    );
    final line = Container(width: 1, height: 24, color: cs.outline);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Material(
          color: cs.surfaceContainerHigh,
          shape: const StadiumBorder(),
          clipBehavior: Clip.antiAlias,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              part(Icons.remove, t('volumeDown'), RemoteKey.volumeDown),
              line,
              part(Icons.volume_off_outlined, t('mute'), RemoteKey.mute),
              line,
              part(Icons.add, t('volumeUp'), RemoteKey.volumeUp),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Semantics(
          label: t('playPause'),
          button: true,
          excludeSemantics: true,
          child: Material(
            color: cs.primary,
            shape: const CircleBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              key: const Key('key-playPause'),
              onTap: () => onKey(RemoteKey.playPause),
              child: SizedBox.square(
                dimension: 60,
                child: Icon(Icons.play_arrow, color: cs.onPrimary, size: 28),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Four wedges and OK. A held arrow repeats after [_delay], every [_every].
class _DPad extends StatefulWidget {
  const _DPad({required this.size, required this.onKey});

  final double size;
  final OnKey onKey;

  @override
  State<_DPad> createState() => _DPadState();
}

class _DPadState extends State<_DPad> {
  static const _delay = Duration(milliseconds: 400);
  static const _every = Duration(milliseconds: 120);
  static const _ok = 0.205;
  RemoteKey? _down;
  Timer? _hold;

  RemoteKey _at(Offset p) {
    final s = widget.size;
    final d = p - Offset(s / 2, s / 2);
    if (d.distance < s * _ok) return RemoteKey.ok;
    if (d.dx.abs() > d.dy.abs()) {
      return d.dx > 0 ? RemoteKey.right : RemoteKey.left;
    }
    return d.dy > 0 ? RemoteKey.down : RemoteKey.up;
  }

  void _start(Offset p) {
    _hold?.cancel();
    final k = _at(p);
    setState(() => _down = k);
    widget.onKey(k);
    if (k == RemoteKey.ok) return;
    _hold = Timer(_delay, () {
      _hold = Timer.periodic(_every, (_) => widget.onKey(k, repeat: true));
    });
  }

  void _end() {
    _hold?.cancel();
    _hold = null;
    if (mounted) setState(() => _down = null);
  }

  @override
  void dispose() {
    _hold?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final s = widget.size;
    Widget arrow(Alignment a, IconData i, RemoteKey k) => Align(
      alignment: a,
      child: Icon(
        i,
        size: s * 0.13,
        color: _down == k ? cs.primary : cs.onSurfaceVariant,
      ),
    );
    return Semantics(
      label: t('dpad'),
      child: GestureDetector(
        key: const Key('pad'),
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _start(d.localPosition),
        onTapUp: (_) => _end(),
        onTapCancel: _end,
        child: SizedBox.square(
          dimension: s,
          child: CustomPaint(
            painter: _Wedges(
              fill: cs.surfaceContainer,
              line: cs.surface,
              pressed: cs.primary.withValues(alpha: 0.18),
              down: _down,
            ),
            child: Stack(
              children: [
                arrow(
                  const Alignment(0, -0.8),
                  Icons.keyboard_arrow_up,
                  RemoteKey.up,
                ),
                arrow(
                  const Alignment(0, 0.8),
                  Icons.keyboard_arrow_down,
                  RemoteKey.down,
                ),
                arrow(
                  const Alignment(-0.8, 0),
                  Icons.keyboard_arrow_left,
                  RemoteKey.left,
                ),
                arrow(
                  const Alignment(0.8, 0),
                  Icons.keyboard_arrow_right,
                  RemoteKey.right,
                ),
                Center(
                  child: Container(
                    width: s * _ok * 2,
                    height: s * _ok * 2,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _down == RemoteKey.ok
                          ? Color.alphaBlend(
                              cs.primary.withValues(alpha: 0.18),
                              cs.surfaceContainerHighest,
                            )
                          : cs.surfaceContainerHighest,
                      border: Border.all(color: cs.surface, width: s * 0.027),
                    ),
                    child: Text(
                      'OK',
                      style: TextStyle(
                        fontSize: s * 0.075,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Wedges extends CustomPainter {
  const _Wedges({
    required this.fill,
    required this.line,
    required this.pressed,
    required this.down,
  });

  final Color fill, line, pressed;
  final RemoteKey? down;

  static const _angles = {
    RemoteKey.right: 0.0,
    RemoteKey.down: 1.5708,
    RemoteKey.left: 3.1416,
    RemoteKey.up: 4.7124,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width / 2;
    final circle = Rect.fromCircle(center: c, radius: r);
    canvas.drawOval(circle, Paint()..color = fill);
    if (_angles[down] case final a?) {
      canvas.drawArc(
        circle,
        a - 0.7854,
        1.5708,
        true,
        Paint()..color = pressed,
      );
    }
    final p = Paint()
      ..color = line
      ..strokeWidth = size.width * 0.018;
    for (final a in [0.7854, 2.3562, 3.927, 5.4978]) {
      final d = Offset.fromDirection(a);
      canvas.drawLine(c + d * r * 0.3, c + d * r, p);
    }
  }

  @override
  bool shouldRepaint(_Wedges old) =>
      old.down != down || old.fill != fill || old.pressed != pressed;
}

/// Swipe mode: each [_step] of a drag is one arrow, a tap is OK.
class _TouchPad extends StatefulWidget {
  const _TouchPad({required this.onKey});

  final OnKey onKey;

  @override
  State<_TouchPad> createState() => _TouchPadState();
}

class _TouchPadState extends State<_TouchPad> {
  static const _step = 40.0;
  Offset _drag = Offset.zero;
  int _steps = 0;

  void _pan(Offset delta) {
    _drag += delta;
    if (_drag.distance < _step) return;
    final d = _drag;
    _drag = Offset.zero;
    widget.onKey(
      d.dx.abs() > d.dy.abs()
          ? (d.dx > 0 ? RemoteKey.right : RemoteKey.left)
          : (d.dy > 0 ? RemoteKey.down : RemoteKey.up),
      repeat: _steps++ > 0,
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      label: t('swipeHint'),
      child: GestureDetector(
        key: const Key('pad'),
        behavior: HitTestBehavior.opaque,
        onTap: () => widget.onKey(RemoteKey.ok),
        onPanStart: (_) {
          _drag = Offset.zero;
          _steps = 0;
        },
        onPanUpdate: (d) => _pan(d.delta),
        child: Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: cs.surfaceContainer,
            borderRadius: BorderRadius.circular(28),
          ),
          alignment: Alignment.bottomCenter,
          padding: const EdgeInsets.all(16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.swipe, size: 18, color: cs.onSurfaceVariant),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  t('swipeHint'),
                  style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
