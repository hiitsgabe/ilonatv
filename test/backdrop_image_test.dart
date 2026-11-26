import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv/ui/backdrop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a backdrop baked after its stream is gone is dropped, not '
      'thrown', (tester) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawRect(
        const Rect.fromLTWH(0, 0, 4, 4),
        Paint()..color = const Color(0xFF336699),
      );
      final image = await recorder.endRecording().toImage(4, 4);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      final provider =
          backdropImage(png!.buffer.asUint8List()) as BackdropImage;
      final completer = provider.loadImage(
        provider,
        PaintingBinding.instance.instantiateImageCodecWithSize,
      );
      // Focus moved on: the only listener goes before the bake is done.
      final listener = ImageStreamListener((_, _) {});
      completer
        ..addListener(listener)
        ..removeListener(listener);
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    expect(tester.takeException(), isNull);
  });
}
