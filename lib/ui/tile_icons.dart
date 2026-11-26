import 'dart:math';

import 'package:flutter/widgets.dart';

/// Corner radius of a tile, in logical pixels.
const tileRadius = 18.0;

enum TileIcon {
  youtube,
  appletv,
  tv,
  prime,
  disney,
  plex,
  kodi,
  twitch,
  spotify,
  apps,
  settings,
}

/// Paints [icon] edge to edge on a 5:3 tile in plain shapes and text. Sizes
/// are fractions of the height.
class TileIconPainter extends CustomPainter {
  final TileIcon icon;
  const TileIconPainter(this.icon);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final c = rect.center;
    final u = size.height;
    final white = Paint()..color = const Color(0xFFFFFFFF);

    void fill(int from, [int? to]) {
      final paint = Paint()..color = Color(from);
      if (to != null) {
        paint.shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(from), Color(to)],
        ).createShader(rect);
      }
      canvas.drawRect(rect, paint);
    }

    void text(
      String s,
      FontWeight weight, {
      double size = 0.45,
      Color color = const Color(0xFFFFFFFF),
      Shader? shader,
      double spacing = 0,
    }) {
      final tp = TextPainter(
        text: TextSpan(
          text: s,
          style: TextStyle(
            fontFamily: 'Inter',
            fontSize: size * u,
            fontWeight: weight,
            letterSpacing: spacing * u,
            color: shader == null ? color : null,
            foreground: shader == null ? null : (Paint()..shader = shader),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, c - Offset(tp.width / 2, tp.height / 2));
      tp.dispose();
    }

    void initial(int color, String letter) {
      fill(color);
      text(letter, FontWeight.w700);
    }

    switch (icon) {
      case TileIcon.youtube:
        fill(0xFFFF2D2D, 0xFFB80000);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: c, width: 0.52 * u, height: 0.36 * u),
            Radius.circular(0.1 * u),
          ),
          white,
        );
        canvas.drawPath(
          Path()
            ..moveTo(c.dx - 0.05 * u, c.dy - 0.095 * u)
            ..lineTo(c.dx + 0.1 * u, c.dy)
            ..lineTo(c.dx - 0.05 * u, c.dy + 0.095 * u)
            ..close(),
          Paint()..color = const Color(0xFFDD0000),
        );
      case TileIcon.appletv:
        fill(0xFF0E0E10);
        // A 1 px edge along the tile's rounded clip, so the near-black tile
        // still reads on TVs that crush blacks.
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            rect.deflate(0.5),
            const Radius.circular(tileRadius - 0.5),
          ),
          Paint()
            ..color = const Color(0xFF2A2A2E)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1,
        );
        text('tv', FontWeight.w600);
      case TileIcon.tv:
        fill(0xFF2B6BFF, 0xFF0B2A7A);
        final line = Paint()
          ..color = const Color(0xFFFFFFFF)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.055 * u
          ..strokeCap = StrokeCap.round;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: c.translate(0, -0.05 * u),
              width: 0.72 * u,
              height: 0.44 * u,
            ),
            Radius.circular(0.07 * u),
          ),
          line,
        );
        canvas.drawLine(
          c.translate(-0.15 * u, 0.28 * u),
          c.translate(0.15 * u, 0.28 * u),
          line,
        );
      case TileIcon.prime:
        initial(0xFF1A98FF, 'P');
      case TileIcon.disney:
        initial(0xFF113CCF, 'D');
      case TileIcon.plex:
        initial(0xFFE5A00D, 'P');
      case TileIcon.kodi:
        initial(0xFF17B2E7, 'K');
      case TileIcon.twitch:
        initial(0xFF9146FF, 'T');
      case TileIcon.spotify:
        initial(0xFF1DB954, 'S');
      case TileIcon.apps:
        fill(0xFF3A3A3E);
        for (var x = -1; x <= 1; x++) {
          for (var y = -1; y <= 1; y++) {
            canvas.drawCircle(
              c.translate(x * 0.17 * u, y * 0.17 * u),
              0.05 * u,
              white,
            );
          }
        }
      case TileIcon.settings:
        fill(0xFF4A4A4E);
        canvas.save();
        canvas.translate(c.dx, c.dy);
        for (var i = 0; i < 8; i++) {
          canvas.drawRRect(
            RRect.fromLTRBR(
              -0.05 * u,
              -0.29 * u,
              0.05 * u,
              0,
              Radius.circular(0.025 * u),
            ),
            white,
          );
          canvas.rotate(pi / 4);
        }
        canvas.restore();
        canvas.drawCircle(c, 0.2 * u, white);
        canvas.drawCircle(
          c,
          0.085 * u,
          Paint()..color = const Color(0xFF4A4A4E),
        );
    }
  }

  @override
  bool shouldRepaint(TileIconPainter oldDelegate) => oldDelegate.icon != icon;
}
