import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/processes.dart';
import '../host.dart';
import '../i18n.dart';
import 'settings_kit.dart';

/// Apps never offered for closing: Ilona TV itself, the Amazon home that
/// Settings and Inputs live in, its settings and the keyboard.
const kKeepRunning = {
  'tv.ilona.app',
  'com.amazon.tv.launcher',
  'com.amazon.firehomestarter',
  'com.amazon.tv.settings.v2',
  'com.amazon.tv.ime',
};

String _mb(int kb) => '${(kb / 1024).round()} MB';

String _state(AppState s) => switch (s) {
  AppState.open => t('stateOpen'),
  AppState.active => t('stateActive'),
  AppState.background => t('stateBackground'),
  AppState.cached => t('stateCached'),
};

/// The installed apps that are running, the most memory first, each a row
/// whose OK closes it; above them the free memory and Clean, which closes them one after
/// another. Closing is Force stop on the app's settings page, clicked by the
/// accessibility service (Fire OS refuses an app's plain kill of another):
/// the screen shows the page for a moment and comes back. Measuring needs
/// DUMP and PACKAGE_USAGE_STATS, granted over adb; without them the pane
/// shows the commands.
class ProcessesPane extends StatefulWidget {
  /// The installed apps by package, with their names: only these are listed.
  final Map<String, InstalledApp> apps;

  /// The commands that grant DUMP, shown when it is missing.
  final List<String> grant;

  /// Tests replace the platform.
  final Future<({String dump, int availKb, int totalKb})> Function() processes;
  final Future<bool> Function(String) killBackground;
  final Future<bool> Function(String) forceStop;
  final Future<Set<String>> Function() keepRunning;

  const ProcessesPane(
    this.apps, {
    super.key,
    required this.grant,
    this.processes = Host.processes,
    this.killBackground = Host.killBackground,
    this.forceStop = Host.forceStop,
    this.keepRunning = Host.keepRunning,
  });

  @override
  State<ProcessesPane> createState() => _ProcessesPaneState();
}

class _ProcessesPaneState extends State<ProcessesPane> {
  Meminfo? _info;
  var _granted = true;
  String? _note;
  final _icons = <String, Uint8List?>{};
  late final AppLifecycleListener _life;
  final _cleanFocus = FocusNode();

  /// [kKeepRunning], and the apps with an accessibility service on and the
  /// keyboard: a force stop would switch those off.
  var _keep = kKeepRunning;

  /// A Close or Clean under way: presses meanwhile do nothing.
  var _busy = false;

  /// Completed when Ilona TV comes back from a Force stop page.
  Completer<void>? _back;
  Future<void>? _inFlight;

  @override
  void initState() {
    super.initState();
    // Back from a Force stop page: the next one may start; measure again.
    _life = AppLifecycleListener(
      onResume: () {
        _back?.complete();
        _back = null;
        _measure();
      },
    );
    widget.keepRunning().then((k) {
      if (mounted) setState(() => _keep = {...kKeepRunning, ...k});
    }, onError: (_) {});
    _measure();
  }

  @override
  void dispose() {
    _life.dispose();
    _cleanFocus.dispose();
    super.dispose();
  }

  List<AppMemory> get _shown => [
    for (final a in _info?.apps ?? const <AppMemory>[])
      if (widget.apps.containsKey(a.package) && !_keep.contains(a.package)) a,
  ];

  /// One measure at a time: one asked meanwhile gets the one running.
  Future<void> _measure() =>
      _inFlight ??= _measureOnce().whenComplete(() => _inFlight = null);

  Future<void> _measureOnce() async {
    if (!mounted) return;
    Meminfo? info;
    try {
      final p = await widget.processes();
      if (parseProcesses(p.dump) case final apps?) {
        info = (apps: apps, freeKb: p.availKb, totalKb: p.totalKb);
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _granted = info != null;
      if (info != null) _info = info;
    });
    // A closed app's card is gone, and focus with it: Clean takes it.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final f = FocusManager.instance.primaryFocus;
      if (mounted && (f == null || f is FocusScopeNode)) {
        _cleanFocus.requestFocus();
      }
    });
    for (final a in _shown) {
      if (_icons.containsKey(a.package)) continue;
      _icons[a.package] = null;
      Host.appIcon(a.package).then((png) {
        if (mounted) setState(() => _icons[a.package] = png);
      }, onError: (_) {});
    }
  }

  /// Force stop on [package]'s page, clicked by the accessibility service,
  /// waiting (up to 8 s) for Ilona TV to come back. Fire OS refuses an app's
  /// plain kill of another ("Invalid packageName"), so this is the one way;
  /// without the service it tries the plain kill anyway and says what is
  /// missing. False when it could not use the page.
  Future<bool> _stop(String package) async {
    final back = _back = Completer<void>();
    if (await widget.forceStop(package)) {
      await back.future.timeout(const Duration(seconds: 8), onTimeout: () {});
      return true;
    }
    _back = null;
    await widget.killBackground(package);
    if (mounted) setState(() => _note = t('needsLauncherMode'));
    return false;
  }

  Future<void> _close(AppMemory app) async {
    if (_busy) return;
    _busy = true;
    try {
      await _stop(app.package);
      await _measure();
    } finally {
      _busy = false;
    }
  }

  /// Each app in turn, the biggest first; it stops at the first that cannot
  /// use the page (no service), then says what it freed.
  Future<void> _clean() async {
    if (_busy) return;
    _busy = true;
    setState(() => _note = t('cleaning'));
    try {
      // The free memory now, not at the last measure.
      final before = (await widget.processes()).availKb;
      for (final a in [..._shown]) {
        if (!await _stop(a.package)) return;
      }
      final after = (await widget.processes()).availKb;
      await _measure();
      if (!mounted) return;
      setState(
        () => _note = t('cleaned').replaceAll(
          '{mb}',
          '${((after - before).clamp(0, 1 << 30) / 1024).round()}',
        ),
      );
    } catch (_) {
      if (mounted) setState(() => _note = null);
    } finally {
      _busy = false;
    }
  }

  /// The free memory over a thin bar, as a row that does not take focus.
  Widget _bar(Meminfo info) {
    final free = info.totalKb == 0 ? 0.0 : info.freeKb / info.totalKb;
    final color = free > 0.25
        ? const Color(0xFF30D158)
        : free > 0.15
        ? const Color(0xFFFFD60A)
        : const Color(0xFFFF453A);
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x14FFFFFF),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 9, 16, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: [
            Text(
              t('memoryFree')
                  .replaceAll('{free}', _mb(info.freeKb))
                  .replaceAll('{total}', _mb(info.totalKb)),
              style: const TextStyle(fontSize: 15, color: Color(0xE6FFFFFF)),
            ),
            ClipRRect(
              borderRadius: const BorderRadius.all(Radius.circular(2)),
              child: LinearProgressIndicator(
                value: 1 - free,
                minHeight: 4,
                color: color,
                backgroundColor: const Color(0x26FFFFFF),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// OK closes it.
  Widget _row(AppMemory a) => SettingsRow(
    key: ValueKey(a.package),
    leading: switch (_icons[a.package]) {
      final png? => ClipRRect(
        borderRadius: const BorderRadius.all(Radius.circular(5)),
        child: Image.memory(png, cacheWidth: 48, fit: BoxFit.cover),
      ),
      null => const Icon(Icons.apps),
    },
    title: widget.apps[a.package]!.label,
    value: '${_mb(a.kb)} · ${_state(a.state)}',
    onPressed: () => _close(a),
  );

  @override
  Widget build(BuildContext context) {
    final info = _info;
    if (!_granted && info == null) {
      return SettingsGroup(
        header: t('processesNeedGrant'),
        // Focusable so the D-pad can scroll down to them.
        children: [
          for (final c in widget.grant) SettingsRow(title: c, mono: true),
        ],
      );
    }
    if (info == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          spacing: 12,
          children: [
            const SizedBox.square(
              dimension: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            Text(t('measuring'), style: settingsNote),
          ],
        ),
      );
    }
    final shown = _shown;
    return settingsGroups([
      SettingsGroup(
        footer: _note,
        children: [
          _bar(info),
          // Always enabled: one that greys out under the D-pad drops focus.
          SettingsRow(
            focusNode: _cleanFocus,
            leading: const Icon(Icons.cleaning_services_outlined),
            title: t('clean'),
            onPressed: _clean,
          ),
        ],
      ),
      SettingsGroup(
        header: t(shown.isEmpty ? 'nothingToClose' : 'okCloses'),
        children: [for (final a in shown) _row(a)],
      ),
    ]);
  }
}
