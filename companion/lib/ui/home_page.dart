import 'package:flutter/material.dart';

import '../adb.dart';
import '../i18n.dart';

import 'package:ilonatv_protocol/releases.dart';

import '../tvs.dart';
import 'about_sheet.dart';
import 'install/install_flow.dart';
import 'pair_page.dart';
import 'remote_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.tvs,
    required this.clientFor,
    this.onInstall,
    this.updates,
  });

  final Tvs tvs;
  final ClientFor clientFor;
  final VoidCallback? onInstall;
  final UpdateCheck? updates;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final AppLifecycleListener _life;
  bool _hidden = false;
  String? _appUpdate;

  @override
  void initState() {
    super.initState();
    widget.updates?.forApp.then((v) {
      if (mounted && v != null) setState(() => _appUpdate = v);
    });
    widget.tvs.startDiscovery();
    _life = AppLifecycleListener(
      onHide: () {
        if (_hidden) return;
        _hidden = true;
        widget.tvs.hold();
      },
      onShow: () {
        if (!_hidden) return;
        _hidden = false;
        widget.tvs.release();
      },
    );
  }

  @override
  void dispose() {
    _life.dispose();
    if (_hidden) widget.tvs.release();
    widget.tvs.stopDiscovery();
    super.dispose();
  }

  void _open(Tv tv) {
    final Widget page = tv.token != null
        ? RemotePage(
            tv: tv,
            client: widget.clientFor(tv),
            tvs: widget.tvs,
            updates: widget.updates,
            onUpdate: widget.onInstall ?? _install,
          )
        : PairPage(tvs: widget.tvs, clientFor: widget.clientFor, host: tv.host);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _pairWithCode() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => PairPage(tvs: widget.tvs, clientFor: widget.clientFor),
    ),
  );

  void _install() => Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) =>
          InstallFlow(adb: Adb(), tvs: widget.tvs, clientFor: widget.clientFor),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.tvs,
          builder: (context, _) {
            final tvs = widget.tvs.all;
            return Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('appName'),
                          style: const TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: t('about'),
                        icon: const Icon(Icons.info_outline),
                        onPressed: () => showModalBottomSheet<void>(
                          context: context,
                          builder: (_) => const AboutSheet(),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (_appUpdate != null)
                    Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 4, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                t('companionUpdate')
                                    .replaceAll('{version}', _appUpdate!),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            TextButton(
                              onPressed: () => openUrl(releasePage),
                              child: Text(t('getIt')),
                            ),
                            IconButton(
                              tooltip: t('close'),
                              onPressed: () =>
                                  setState(() => _appUpdate = null),
                              icon: const Icon(Icons.close),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Expanded(
                    child: tvs.isEmpty
                        ? _Empty()
                        : ListView.separated(
                            itemCount: tvs.length,
                            separatorBuilder: (_, _) =>
                                const SizedBox(height: 12),
                            itemBuilder: (_, i) =>
                                _TvCard(tv: tvs[i], onTap: () => _open(tvs[i])),
                          ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _pairWithCode,
                    icon: const Icon(Icons.pin_outlined),
                    label: Text(t('pairWithCode')),
                    style: _big,
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: widget.onInstall ?? _install,
                    icon: const Icon(Icons.download_outlined),
                    label: Text(t('installOnTv')),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(56),
                      foregroundColor: Colors.white,
                      side: const BorderSide(color: Color(0x66FFFFFF)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(18),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static final _big = FilledButton.styleFrom(
    minimumSize: const Size.fromHeight(56),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
  );
}

class _Empty extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.tv, size: 72, color: Color(0x66FFFFFF)),
        const SizedBox(height: 16),
        Text(
          t('noTvs'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16),
        ),
      ],
    ),
  );
}

class _TvCard extends StatelessWidget {
  const _TvCard({required this.tv, required this.onTap});

  final Tv tv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    clipBehavior: Clip.antiAlias,
    child: InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.tv, size: 32),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tv.label,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${tv.host}  ·  ${tv.token != null ? t('paired') : t('tapToPair')}',
                    style: const TextStyle(color: Color(0xB3FFFFFF)),
                  ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
      ),
    ),
  );
}
