import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A row's lead-in before its first card's focus box: the home's left margin
/// (0.04 of the width) less the half gap each card carries inside its focus.
/// The traversal keeps a focused card there, so the first card, scrolled back
/// to, lands where it started.
const kRowLeadIn = 0.04 - 0.014 / 2;

/// Arrow-key traversal for the home's rows: it moves focus like the default
/// policy, but scrolls only the horizontal list a card sits in, and to the
/// row's margin, not the screen's edge. The home animates its own vertical
/// scroll; the default's instant jump of the outer scroll view made the row
/// leaving upward flash over the highlight.
FocusTraversalPolicy rowsTraversalPolicy() =>
    ReadingOrderTraversalPolicy(requestFocusCallback: focusInRow);

/// Focuses [node] and scrolls its row to put it at the lead-in.
void focusInRow(
  FocusNode node, {
  ScrollPositionAlignmentPolicy? alignmentPolicy,
  double? alignment,
  Duration? duration,
  Curve? curve,
}) {
  node.requestFocus();
  final context = node.context;
  if (context == null) return;
  final scrollable = Scrollable.maybeOf(context, axis: Axis.horizontal);
  final object = context.findRenderObject();
  if (scrollable == null || object == null) return;
  final viewport = RenderAbstractViewport.maybeOf(object);
  if (viewport == null) return;
  final position = scrollable.position;
  // The card's left edge at the lead-in: the offset that puts it on the
  // viewport's edge, less the margin. Never before the list's start.
  final target =
      viewport.getOffsetToReveal(object, 0).offset -
      kRowLeadIn * position.viewportDimension;
  position.animateTo(
    target.clamp(position.minScrollExtent, position.maxScrollExtent),
    duration: const Duration(milliseconds: 150),
    curve: Curves.ease,
  );
}
