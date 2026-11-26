import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../host.dart';
import '../i18n.dart';
import '../settings.dart';
import 'glass.dart';
import 'tile.dart';
import 'rows_traversal.dart';

/// The row of app tiles along the bottom of the home screen, on a glass dock
/// 24 px wider than the tiles all round.
class AppRow extends StatelessWidget {
  final List<AppTile> tiles;
  final Map<String, InstalledApp> apps;
  final Map<String, Uint8List?> icons;
  final void Function(AppTile) onOpen;
  final VoidCallback onLongPress;

  const AppRow({
    super.key,
    required this.tiles,
    required this.apps,
    required this.icons,
    required this.onOpen,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    // ponytail: a Row fits five tiles at these sizes; put it in a horizontal
    // scroll view when rows get longer.
    return FocusTraversalGroup(
      policy: rowsTraversalPolicy(),
      // The tiles keep the screen's 4 % margin; the dock reaches past it.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: max(0, 0.04 * w - 24)),
        // Its own layer: the dock's shadow and glass do not repaint with the
        // rows scrolling past.
        child: RepaintBoundary(
          child: Glass(
            radius: 28,
            padding: const EdgeInsets.all(24),
            blur: kDockBlur,
            child: Row(
              spacing: 0.022 * 1.04 * w,
              children: [
                for (final (i, tile) in tiles.indexed)
                  SizedBox(
                    width: 0.165 * 0.92 * 1.04 * w,
                    // Tiles are icon only, so screen readers get the app's name;
                    // a pseudo package's suffix is its i18n key.
                    child: Semantics(
                      label:
                          apps[tile.package]?.label ??
                          t(tile.package.replaceFirst('ilonatv:', '')),
                      // A lift repaints this tile only.
                      child: RepaintBoundary(
                        child: Tile(
                          tile: tile,
                          realIcon: icons[tile.package],
                          autofocus: i == 0,
                          onOpen: () => onOpen(tile),
                          onLongPress: onLongPress,
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
