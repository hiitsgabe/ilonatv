import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'host.dart';
import 'settings.dart';

/// Hands the home screen, as last drawn, to the Fire TV curtain (Curtain.kt)
/// each time Ilona TV leaves the screen, so a Home press shows Ilona TV instead of
/// the Amazon home while Ilona TV comes back. Only in Launcher mode, the one
/// place the curtain is drawn.
class SnapshotObserver extends WidgetsBindingObserver {
  final GlobalKey boundaryKey;
  final Settings settings;
  SnapshotObserver(this.boundaryKey, this.settings);

  var _wasResumed = true;

  // Inactive comes on the way back up too; that frame is the one already sent.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive && _wasResumed) _capture();
    _wasResumed = state == AppLifecycleState.resumed;
  }

  Future<void> _capture() async {
    if (!settings.fireTvMode) return;
    // The backdrop settles its crossfade on this same change; the next frame
    // paints that. Frames still run while inactive; should the app be hidden
    // first, the capture waits for the next frame there is.
    await WidgetsBinding.instance.endOfFrame;
    final boundary = boundaryKey.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary) return;
    try {
      // 640 px wide, raw pixels: under 1 MB across the channel and nothing to
      // encode or decode, so the curtain has it within its first frames (a
      // PNG took the TV longer than the curtain was up). Stretched to the
      // screen, it is a blur for a moment, which is what a curtain is.
      final image = await boundary.toImage(
        pixelRatio: 640 / boundary.size.width,
      );
      final rgba = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      final (w, h) = (image.width, image.height);
      image.dispose();
      if (rgba != null) {
        await Host.setSnapshot(rgba.buffer.asUint8List(), w, h);
      }
    } catch (e) {
      debugPrint('snapshot failed: $e');
    }
  }
}
