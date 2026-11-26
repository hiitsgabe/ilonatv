import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../host.dart';
import '../settings.dart';
import 'tile.dart';

/// [apps] (the offered ones, `offeredApps`) as tiles with their names below,
/// in [apps] order (by label). OK opens the app; Back returns.
class AppsScreen extends StatelessWidget {
  final Map<String, InstalledApp> apps;
  const AppsScreen(this.apps, {super.key});

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final gap = 0.022 * w;
    final cell = (0.92 * w - 5 * gap) / 6;
    final list = apps.values.toList();
    return Scaffold(
      body: GridView.builder(
        padding: EdgeInsets.symmetric(horizontal: 0.04 * w, vertical: 0.05 * w),
        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 6,
          crossAxisSpacing: gap,
          mainAxisSpacing: gap,
          mainAxisExtent: cell * 3 / 5 + 40,
        ),
        itemCount: list.length,
        itemBuilder: (_, i) => _AppCell(list[i], autofocus: i == 0),
      ),
    );
  }
}

class _AppCell extends StatefulWidget {
  final InstalledApp app;
  final bool autofocus;
  const _AppCell(this.app, {required this.autofocus});

  @override
  State<_AppCell> createState() => _AppCellState();
}

class _AppCellState extends State<_AppCell> {
  Uint8List? _icon;

  // ponytail: each cell fetches its own icon and drops it when the grid
  // disposes the cell, so scrolling back fetches again; share one cache by
  // package (like the home's) if that gets slow.
  @override
  void initState() {
    super.initState();
    _loadIcon();
  }

  /// Its decoded icon goes with the cell: every visit fetches new bytes, so
  /// it would only sit in [imageCache].
  @override
  void dispose() {
    if (_icon case final png?) MemoryImage(png).evict();
    super.dispose();
  }

  /// A failed fetch leaves the tile grey.
  Future<void> _loadIcon() async {
    try {
      final png = await Host.appIcon(widget.app.package);
      if (mounted) setState(() => _icon = png);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Tile(
          tile: AppTile(widget.app.package, 'app'),
          realIcon: _icon,
          autofocus: widget.autofocus,
          onOpen: () => Host.launch(widget.app.package),
          onLongPress: () {},
        ),
        Text(
          widget.app.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: Color(0xB3FFFFFF)),
        ),
      ],
    ),
  );
}
