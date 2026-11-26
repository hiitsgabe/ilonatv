import 'package:flutter/painting.dart';

import 'host.dart';

/// How much the home may spend on images, by the device's RAM. The first Fire
/// TV Stick (1.7 GB, ~300 MB free) set the floor: 8 MB of decoded images and
/// rows loading theirs only next to the focused one, which shows a grey box
/// for a moment on a fast scroll. A TV with more room keeps more rows ready.
class Device {
  /// Rows this far from the focused one keep their images.
  static int rowWindow = 1;

  /// Reads the RAM and sets [rowWindow] and the image cache. Call once, early.
  static Future<void> tune() async {
    final mb = await Host.deviceMemoryKb() ~/ 1024;
    final (cache, window) = switch (mb) {
      >= 3000 => (48, 3),
      >= 1500 => (24, 2),
      _ => (8, 1),
    };
    imageCache.maximumSizeBytes = cache << 20;
    rowWindow = window;
  }
}
