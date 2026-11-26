import 'package:flutter/material.dart';
import 'package:qr/qr.dart' as qr;

class QrCode extends StatelessWidget {
  const QrCode(this.data, {super.key, this.size = 220});

  final String data;
  final double size;

  @override
  Widget build(BuildContext context) {
    final image = qr.QrImage(
      qr.QrCode(
        payload: qr.QrPayload.fromString(data),
        errorCorrectLevel: qr.QrErrorCorrectLevel.medium,
      ),
    );
    return SizedBox.square(
      dimension: size,
      child: CustomPaint(painter: _QrPainter(image)),
    );
  }
}

class _QrPainter extends CustomPainter {
  _QrPainter(this.image);

  final qr.QrImage image;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        Radius.circular(size.width / 16),
      ),
      Paint()..color = Colors.white,
    );
    final n = image.moduleCount;
    final cell = size.width / (n + 8);
    final ink = Paint()..color = Colors.black;
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        if (image.isDark(y, x)) {
          canvas.drawRect(
            Rect.fromLTWH((x + 4) * cell, (y + 4) * cell, cell, cell),
            ink,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(_QrPainter old) => old.image != image;
}
