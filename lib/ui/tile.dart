import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../settings.dart';
import 'glass.dart';
import 'tile_icons.dart';

final _iconsByName = TileIcon.values.asNameMap();

const _radius = BorderRadius.all(Radius.circular(tileRadius));

/// One 5:3 icon tile. OK, Enter or a gamepad's A calls [onOpen] on release;
/// holding one for 600 ms calls [onLongPress] instead.
class Tile extends StatefulWidget {
  final AppTile tile;
  final Uint8List? realIcon;
  final bool autofocus;
  final VoidCallback onOpen;
  final VoidCallback onLongPress;

  const Tile({
    super.key,
    required this.tile,
    this.realIcon,
    this.autofocus = false,
    required this.onOpen,
    required this.onLongPress,
  });

  @override
  State<Tile> createState() => _TileState();
}

class _TileState extends State<Tile> {
  bool _focused = false;

  /// Runs while OK is down on this tile and no action has fired yet.
  Stopwatch? _held;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    final k = e.logicalKey;
    if (k != LogicalKeyboardKey.select &&
        k != LogicalKeyboardKey.enter &&
        k != LogicalKeyboardKey.numpadEnter &&
        k != LogicalKeyboardKey.gameButtonA) {
      return KeyEventResult.ignored;
    }
    if (e is KeyDownEvent) {
      _held = Stopwatch()..start();
    } else if (e is KeyRepeatEvent &&
        (_held?.elapsedMilliseconds ?? 0) >= 600) {
      _held = null;
      widget.onLongPress();
    } else if (e is KeyUpEvent && _held != null) {
      _held = null;
      widget.onOpen();
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final painted = _iconsByName[widget.tile.icon];
    final real = widget.realIcon;
    return Focus(
      autofocus: widget.autofocus,
      // A press only counts if it starts and ends while this tile has focus.
      onFocusChange: (f) => setState(() {
        _focused = f;
        _held = null;
      }),
      onKeyEvent: _onKey,
      child: FocusLift(
        focused: _focused,
        radius: tileRadius,
        child: AspectRatio(
          aspectRatio: 5 / 3,
          child: RepaintBoundary(
            child: ClipRRect(
              borderRadius: _radius,
              child: widget.tile.image != null
                  ? _picture(widget.tile)
                  : painted != null
                  ? CustomPaint(painter: TileIconPainter(painted))
                  : real != null
                  ? Image.memory(real, fit: BoxFit.cover)
                  : _grey,
            ),
          ),
        ),
      ),
    );
  }
}

const _grey = ColoredBox(color: Color(0xFF2C2C30));

/// The tile's own picture; one that no longer reads is a grey card. The copy
/// is already scaled down to a tile's size (HostChannel.copyImage).
Widget _picture(AppTile tile) {
  final image = Image.file(
    File(tile.image!),
    fit: tile.centered ? BoxFit.contain : BoxFit.cover,
    errorBuilder: (_, _, _) => _grey,
  );
  if (!tile.centered) return image;
  final inner = FractionallySizedBox(
    widthFactor: 0.8,
    heightFactor: 0.7,
    child: image,
  );
  final background = tile.background;
  return background == null
      ? Glass(radius: tileRadius, child: inner)
      : ColoredBox(color: Color(background), child: inner);
}
