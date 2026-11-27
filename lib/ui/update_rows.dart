import 'dart:async';

import 'package:flutter/material.dart';
import 'package:ilonatv_protocol/releases.dart';

import '../app.dart';
import '../host.dart';
import '../i18n.dart';
import 'settings_kit.dart';

/// The page went away mid-download.
class _Cancelled implements Exception {
  const _Cancelled();
}

class _InstallFailed implements Exception {
  const _InstallFailed(this.why);
  final String why;
}

/// Settings > About's version, then "Check for updates", which becomes
/// "Update to vX.Y.Z" when GitHub's latest release is newer. The update
/// downloads the APK for this TV's ABI into the cache, checks its SHA-256
/// and has the system install it over Ilona TV.
class UpdateRows extends StatefulWidget {
  final ReleaseSource releases;
  const UpdateRows({super.key, this.releases = const ReleaseSource()});

  @override
  State<UpdateRows> createState() => _UpdateRowsState();
}

class _UpdateRowsState extends State<UpdateRows> {
  ReleaseAsset? _newer;
  String? _value;
  String? _note;
  var _busy = false;

  // The system's confirm came and went: an answer may never come (an update
  // that went through ends this process), so the row is free again.
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onResume: () {
        if (_busy && _value == t('installing')) {
          setState(() {
            _busy = false;
            _value = null;
          });
        }
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _note = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) {
        setState(() {
          _value = null;
          _note = _why(e);
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _why(Object e) => switch (e) {
    RateLimited() => t('updateRateLimited'),
    NoAsset() => t('updateNoApk'),
    BadChecksum() => t('updateBadChecksum'),
    _InstallFailed(:final why) => t(
      'updateInstallFailed',
    ).replaceAll('{why}', why),
    _ => t('updateOffline'),
  };

  Future<void> _check() => _run(() async {
    setState(() => _value = t('checking'));
    final abi = pickAbi(await Host.abis());
    if (abi == null) throw const NoAsset();
    final a = await widget.releases.latest(abi);
    setState(() {
      _newer = a != null && isOlder(kVersion, a.version) ? a : null;
      _value = _newer == null ? t('upToDate') : null;
    });
  });

  Future<void> _update(ReleaseAsset a) => _run(() async {
    if (!await Host.canInstall()) {
      await Host.openSystemSettings(
        action: 'android.settings.MANAGE_UNKNOWN_APP_SOURCES',
        data: 'package:tv.ilona.app',
        pause: true,
      );
      // Fire OS may have no such screen; the note says where it lives there.
      if (mounted) setState(() => _note = t('allowInstalls'));
      return;
    }
    var shown = -1;
    await selfUpdate(
      widget.releases,
      a,
      await Host.cacheDir(),
      (path) async {
        if (!mounted) return;
        setState(() => _value = t('installing'));
        final why = await Host.installApk(path);
        if (why != null) throw _InstallFailed(why);
      },
      progress: (got, total) {
        final pct = total > 0 ? 100 * got ~/ total : 0;
        if (!mounted) throw const _Cancelled();
        if (pct == shown) return;
        shown = pct;
        setState(() => _value = '$pct%');
      },
    );
  });

  @override
  Widget build(BuildContext context) {
    final newer = _newer;
    return SettingsGroup(
      footer: _note,
      children: [
        SettingsRow(title: t('version'), value: kVersion),
        SettingsRow(
          title: newer == null
              ? t('checkUpdates')
              : t('updateTo').replaceAll('{version}', newer.version),
          value: _value,
          primary: newer != null,
          onPressed: _busy
              ? null
              : newer == null
              ? _check
              : () => _update(newer),
        ),
      ],
    );
  }
}
