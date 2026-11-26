import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// A real blur behind the home's dock. Off until a pass on the TV shows frames
/// stay under 16 ms with it; the gradient reads as glass over the dimmed
/// backdrop without it.
const kDockBlur = false;

const _glassShadow = BoxShadow(
  color: Color(0x66000000),
  blurRadius: 30,
  offset: Offset(0, 10),
);

/// A rounded pane of glass: a translucent white gradient, a 1 px edge that
/// catches light at the top, and a soft shadow. [blur] adds a real backdrop
/// blur (sigma 24), the dock's only.
class Glass extends StatelessWidget {
  final Widget child;
  final double radius;
  final EdgeInsets padding;
  final bool blur;

  const Glass({
    super.key,
    required this.child,
    this.radius = 22,
    this.padding = EdgeInsets.zero,
    this.blur = false,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.all(Radius.circular(radius));
    Widget pane = CustomPaint(
      painter: _GlassPainter(radius),
      child: Padding(padding: padding, child: child),
    );
    if (blur) {
      pane = ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: pane,
        ),
      );
    }
    return CustomPaint(painter: _ShadowPainter(radius), child: pane);
  }
}

/// The shadow, outside the rounded rect only: under the translucent fill it
/// would darken the glass.
class _ShadowPainter extends CustomPainter {
  final double radius;
  const _ShadowPainter(this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(radius));
    canvas
      ..save()
      ..clipPath(
        Path()
          ..fillType = PathFillType.evenOdd
          ..addRect(rect.inflate(100))
          ..addRRect(rrect),
      )
      ..drawRRect(rrect.shift(_glassShadow.offset), _glassShadow.toPaint())
      ..restore();
  }

  @override
  bool shouldRepaint(_ShadowPainter old) => old.radius != radius;
}

class _GlassPainter extends CustomPainter {
  final double radius;
  const _GlassPainter(this.radius);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(radius)),
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x2EFFFFFF), Color(0x14FFFFFF)],
        ).createShader(rect),
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect.deflate(0.5), Radius.circular(radius - 0.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x66FFFFFF), Color(0x14FFFFFF)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_GlassPainter old) => old.radius != radius;
}

const _liftShadow = BoxShadow(
  color: Color(0xCC000000),
  blurRadius: 32,
  offset: Offset(0, 16),
);

/// Focus on a tile or a card: it rises 6 px and grows to 1.08, over a deeper
/// shadow, with a thin specular sheen on its top third. Only the transform
/// animates; the shadow and the sheen switch at once, so no blur is animated.
class FocusLift extends StatelessWidget {
  final bool focused;
  final Widget child;
  final double radius;

  const FocusLift({
    super.key,
    required this.focused,
    required this.child,
    this.radius = 0,
  });

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.all(Radius.circular(radius));
    return TweenAnimationBuilder<double>(
      tween: Tween(end: focused ? 1 : 0),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      // Both decorations stay, empty or not, so a focus change keeps the
      // tree's shape and does not tear down what is below.
      child: Container(
        decoration: focused
            ? BoxDecoration(borderRadius: r, boxShadow: const [_liftShadow])
            : const BoxDecoration(),
        foregroundDecoration: focused
            ? BoxDecoration(
                borderRadius: r,
                // A thin bright edge: on a dark backdrop the lift's shadow
                // alone does not read as focus from the couch.
                border: Border.all(color: const Color(0xB3FFFFFF), width: 2),
                gradient: const LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment(0, -1 / 3),
                  colors: [Color(0x40FFFFFF), Color(0x00FFFFFF)],
                ),
              )
            : const BoxDecoration(),
        child: child,
      ),
      builder: (_, v, child) => Transform.translate(
        offset: Offset(0, -6 * v),
        child: Transform.scale(scale: 1 + 0.08 * v, child: child),
      ),
    );
  }
}
