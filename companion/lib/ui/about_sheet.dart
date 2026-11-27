import 'package:flutter/material.dart';
import 'package:ilonatv_protocol/releases.dart';

import '../i18n.dart';
import '../tvs.dart';

/// The page went away mid-download.
class _Cancelled implements Exception {
  const _Cancelled();
}

class _InstallFailed implements Exception {
  const _InstallFailed(this.why);
  final String why;
}

/// The companion's version, then "Check for updates", which becomes
/// "Update to vX.Y.Z" when the latest release is newer: its APK downloads
/// into the cache, its SHA-256 is checked and the system installs it.
class AboutSheet extends StatefulWidget {
  const AboutSheet({super.key, this.releases = const ReleaseSource()});

  final ReleaseSource releases;

  @override
  State<AboutSheet> createState() => _AboutSheetState();
}

class _AboutSheetState extends State<AboutSheet> {
  String? _version;
  ReleaseAsset? _newer;
  String? _status;
  String? _note;
  var _busy = false;

  // The system's confirm came and went: an answer may never come (an update
  // that went through ends this process), so the row is free again.
  late final AppLifecycleListener _life;

  @override
  void dispose() {
    _life.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _life = AppLifecycleListener(
      onResume: () {
        if (_busy && _status == t('installing')) {
          setState(() {
            _busy = false;
            _status = null;
          });
        }
      },
    );
    appVersion().then((v) {
      if (mounted) setState(() => _version = v);
    });
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
          _status = null;
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
    setState(() => _status = t('checking'));
    final a = await widget.releases.named('ilonatv-companion.apk');
    final v = _version;
    setState(() {
      _newer = a != null && v != null && isOlder(v, a.version) ? a : null;
      _status = _newer == null ? t('upToDate') : null;
    });
  });

  Future<void> _update(ReleaseAsset a) => _run(() async {
    if (!await canInstall()) {
      await allowInstalls();
      if (mounted) setState(() => _note = t('allowInstalls'));
      return;
    }
    var shown = -1;
    await selfUpdate(
      widget.releases,
      a,
      await cacheDir(),
      (path) async {
        if (!mounted) return;
        setState(() => _status = t('installing'));
        final why = await installApk(path);
        if (why != null) throw _InstallFailed(why);
      },
      progress: (got, total) {
        final pct = total > 0 ? 100 * got ~/ total : 0;
        if (!mounted) throw const _Cancelled();
        if (pct == shown) return;
        shown = pct;
        setState(() => _status = '$pct%');
      },
    );
  });

  @override
  Widget build(BuildContext context) {
    final newer = _newer;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(title: Text(t('version')), trailing: Text(_version ?? '')),
          ListTile(
            leading: const Icon(Icons.system_update_outlined),
            title: Text(
              newer == null
                  ? t('checkUpdates')
                  : t('updateTo').replaceAll('{version}', newer.version),
            ),
            trailing: _status == null ? null : Text(_status!),
            enabled: !_busy,
            onTap: newer == null ? _check : () => _update(newer),
          ),
          if (_note case final n?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Text(
                n,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }
}
