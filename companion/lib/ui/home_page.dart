import 'dart:async';

import 'package:flutter/material.dart';

import '../adb.dart';
import '../i18n.dart';

import 'package:ilonatv_protocol/releases.dart';

import '../tvs.dart';
import 'about_sheet.dart';
import 'install/install_flow.dart';
import 'pair_page.dart';
import 'remote_page.dart';
import 'theme.dart';

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
  bool _autoOpened = false;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    widget.updates?.forApp.then((v) {
      if (mounted && v != null) setState(() => _appUpdate = v);
    });
    widget.tvs.addListener(_found);
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
    _settle?.cancel();
    widget.tvs.removeListener(_found);
    _life.dispose();
    if (_hidden) widget.tvs.release();
    widget.tvs.stopDiscovery();
    super.dispose();
  }

  // TVs answer discovery one by one: a short wait, so a second one online
  // isn't missed.
  void _found() {
    if (_autoOpened) return;
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 800), () {
      final online = [
        for (final tv in widget.tvs.all)
          if (tv.token != null && tv.found) tv,
      ];
      if (_autoOpened || !mounted || online.length != 1) return;
      if (!(ModalRoute.of(context)?.isCurrent ?? false)) return;
      _open(online.single);
    });
  }

  // Anything opened from Home ends the auto-open: Back must land on Home.
  void _push(Widget page) {
    _autoOpened = true;
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _open(Tv tv) {
    final Widget page = tv.token != null
        ? RemotePage(
            tv: tv,
            client: widget.clientFor(tv),
            tvs: widget.tvs,
            updates: widget.updates,
            onUpdate: _install,
            clientFor: widget.clientFor,
          )
        : PairPage(tvs: widget.tvs, clientFor: widget.clientFor, host: tv.host);
    _push(page);
  }

  void _pair({bool scan = false}) =>
      _push(PairPage(tvs: widget.tvs, clientFor: widget.clientFor, scan: scan));

  void _install() {
    if (widget.onInstall case final f?) {
      _autoOpened = true;
      return f();
    }
    _push(
      InstallFlow(adb: Adb(), tvs: widget.tvs, clientFor: widget.clientFor),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final install = TextButton.icon(
      onPressed: _install,
      icon: const Icon(Icons.download_outlined),
      label: Text(t('installOnTv')),
    );
    return Scaffold(
      body: SafeArea(
        child: ListenableBuilder(
          listenable: widget.tvs,
          builder: (context, _) {
            final all = widget.tvs.all;
            final paired = [
              for (final tv in all)
                if (tv.token != null) tv,
            ];
            final unpaired = [
              for (final tv in all)
                if (tv.token == null) tv,
            ];
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          t('appName'),
                          style: const TextStyle(
                            fontSize: 24,
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
                  const SizedBox(height: 12),
                  if (_appUpdate != null) ...[
                    _UpdateBanner(
                      version: _appUpdate!,
                      onClose: () => setState(() => _appUpdate = null),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Expanded(
                    child: all.isEmpty
                        ? _Empty(
                            onScan: () => _pair(scan: true),
                            onCode: _pair,
                            install: install,
                          )
                        : ListView(
                            children: [
                              if (paired.isNotEmpty) ...[
                                _Header(t('yourTvs')),
                                for (final tv in paired)
                                  _TvCard(tv: tv, onTap: () => _open(tv)),
                              ],
                              if (unpaired.isNotEmpty) ...[
                                _Header(t('foundHere')),
                                for (final tv in unpaired)
                                  _TvCard(tv: tv, onTap: () => _open(tv)),
                              ],
                            ],
                          ),
                  ),
                  if (all.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    FilledButton.tonalIcon(
                      onPressed: _pair,
                      icon: const Icon(Icons.add),
                      label: Text(t('addTv')),
                      style: FilledButton.styleFrom(
                        backgroundColor: cs.surfaceContainerHighest,
                        foregroundColor: cs.onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    install,
                  ],
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );
}

class _UpdateBanner extends StatelessWidget {
  const _UpdateBanner({required this.version, required this.onClose});

  final String version;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
      decoration: BoxDecoration(
        color: cs.primaryContainer,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.download_outlined, color: cs.onPrimaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              t('companionUpdate').replaceAll('{version}', version),
              style: TextStyle(
                color: cs.onPrimaryContainer,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: cs.onPrimaryContainer),
            onPressed: () => openUrl(releasePage),
            child: Text(t('getIt')),
          ),
          IconButton(
            tooltip: t('close'),
            color: cs.onPrimaryContainer,
            onPressed: onClose,
            icon: const Icon(Icons.close, size: 20),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.onScan,
    required this.onCode,
    required this.install,
  });

  final VoidCallback onScan;
  final VoidCallback onCode;
  final Widget install;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Spacer(),
        // Still under a sheet or a page, so the ping doesn't run behind them.
        TickerMode(
          enabled: ModalRoute.of(context)?.isCurrent ?? true,
          child: const Center(child: _Radar()),
        ),
        const SizedBox(height: 20),
        Text(
          t('searchingTvs'),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Text(
            t('searchingHint'),
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
        const Spacer(),
        FilledButton.icon(
          onPressed: onScan,
          icon: const Icon(Icons.qr_code_scanner),
          label: Text(t('scanQr')),
        ),
        const SizedBox(height: 10),
        FilledButton.tonalIcon(
          onPressed: onCode,
          icon: const Icon(Icons.pin_outlined),
          label: Text(t('typeCode')),
          style: FilledButton.styleFrom(
            backgroundColor: cs.surfaceContainerHighest,
            foregroundColor: cs.onSurface,
          ),
        ),
        const SizedBox(height: 14),
        const Divider(height: 1),
        const SizedBox(height: 10),
        Text(
          t('noTvAppYet'),
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
        ),
        install,
      ],
    );
  }
}

class _Radar extends StatefulWidget {
  const _Radar();

  @override
  State<_Radar> createState() => _RadarState();
}

class _RadarState extends State<_Radar> with SingleTickerProviderStateMixin {
  late final _ping = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ping.stop();
    } else if (!_ping.isAnimating) {
      _ping.repeat();
    }
  }

  @override
  void dispose() {
    _ping.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    Widget ring(double size, double alpha) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: cs.primary.withValues(alpha: alpha),
          width: 2,
        ),
      ),
    );
    return SizedBox.square(
      dimension: 132,
      child: Stack(
        alignment: Alignment.center,
        children: [
          ring(132, 0.08),
          ring(96, 0.14),
          AnimatedBuilder(
            animation: _ping,
            builder: (_, _) => Opacity(
              opacity: (1 - _ping.value) * 0.7,
              child: ring(46 + 86 * _ping.value, 1),
            ),
          ),
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: cs.surfaceContainerHigh,
            ),
            child: Icon(Icons.tv, color: cs.primary),
          ),
        ],
      ),
    );
  }
}

class _TvCard extends StatelessWidget {
  const _TvCard({required this.tv, required this.onTap});

  final Tv tv;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final paired = tv.token != null;
    final muted = TextStyle(fontSize: 13, color: cs.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Material(
        color: paired ? cs.surfaceContainer : Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: paired ? BorderSide.none : BorderSide(color: cs.outline),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: paired
                        ? cs.surfaceContainerHighest
                        : cs.surfaceContainer,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(Icons.tv, color: cs.primary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tv.label,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      if (paired)
                        Row(
                          children: [
                            StatusDot(
                              tv.found ? Tones.ok : cs.onSurfaceVariant,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                t(tv.found ? 'online' : 'offline'),
                                style: muted,
                              ),
                            ),
                          ],
                        )
                      else
                        Text(t('tapToPair'), style: muted),
                    ],
                  ),
                ),
                if (paired)
                  Icon(Icons.chevron_right, color: cs.onSurfaceVariant)
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: cs.primaryContainer,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      t('pairNow'),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: cs.onPrimaryContainer,
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
