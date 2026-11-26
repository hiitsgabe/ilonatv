import 'package:flutter/material.dart';

import '../data/media.dart';
import '../disk_images.dart';
import '../i18n.dart';

const _titleStyle = TextStyle(
  fontSize: 44,
  fontWeight: FontWeight.w700,
  color: Colors.white,
  height: 1.15,
);
const _chipStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: Color(0xE6FFFFFF),
  height: 1.2,
);
const _starStyle = TextStyle(
  fontSize: 15,
  fontWeight: FontWeight.w600,
  color: Color(0xFFF5C518),
  height: 1.2,
);
const _overviewStyle = TextStyle(
  fontSize: 15,
  height: 1.3,
  color: Color(0x99FFFFFF),
);

/// The item on the backdrop: its title, chips for what is known of it (year,
/// genre, ★ rating), two lines of synopsis, and a "Watch" button (or "Watch
/// on [watchOn]") when [onOpen] is given, with a small trailer button beside
/// it when [onTrailer] is.
/// Nothing without an item.
///
/// The block is anchored at its bottom, so every part keeps a fixed height
/// whether or not the item has it: the chip line, the two synopsis lines and
/// the buttons' room are always there (the buttons hidden, not removed, while
/// a card has the focus). Only the title grows, upward.
class Highlight extends StatelessWidget {
  final MediaItem? item;
  final VoidCallback? onOpen;
  final VoidCallback? onTrailer;

  /// The title's logo image (TMDB), drawn in the title's box in place of the
  /// text when given and once it loads.
  final String? logoUrl;

  /// A bundled logo drawn white in the title's box (a console's wordmark);
  /// wins over [logoUrl].
  final String? logoAsset;

  /// Whether the item has a logo is still being asked: the title's box stays
  /// empty meanwhile, so the name never flashes before its logo.
  final bool logoPending;

  /// The service the title opens in, named on the button; null for "Watch".
  final String? watchOn;

  const Highlight({
    super.key,
    required this.item,
    this.onOpen,
    this.onTrailer,
    this.logoUrl,
    this.logoAsset,
    this.logoPending = false,
    this.watchOn,
  });

  @override
  Widget build(BuildContext context) {
    final item = this.item;
    if (item == null) return const SizedBox.shrink();
    final scale = MediaQuery.textScalerOf(context);
    final chipLine = scale.scale(_chipStyle.fontSize!) * _chipStyle.height! + 6;
    final overviewLines =
        scale.scale(_overviewStyle.fontSize!) * _overviewStyle.height! * 2;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _FitTitle(
          item.title,
          logoUrl: logoUrl,
          logoAsset: logoAsset,
          pending: logoPending,
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: chipLine,
          child: Row(
            children: [
              if (item.year case final year?) _Chip(year.toString()),
              if (item.genre.isNotEmpty) _Chip(item.genre),
              if (item.rating case final rating?)
                _Chip(rating.toString(), star: true),
            ],
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: overviewLines,
          width: 620,
          child: Text(
            item.overview ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: _overviewStyle,
          ),
        ),
        const SizedBox(height: 12),
        // Hidden, not gone, while a card has the focus: the text above stays put.
        ExcludeFocus(
          excluding: onOpen == null,
          child: Visibility(
            visible: onOpen != null,
            maintainSize: true,
            maintainAnimation: true,
            maintainState: true,
            child: _Buttons(
              onOpen: onOpen ?? () {},
              onTrailer: onTrailer,
              label: watchOn == null
                  ? t('watch')
                  : t('watchOn').replaceAll('{service}', watchOn!),
            ),
          ),
        ),
      ],
    );
  }
}

/// A small glass tag: "2024", "Action", "★ 7.8".
class _Chip extends StatelessWidget {
  final String text;
  final bool star;
  const _Chip(this.text, {this.star = false});

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(right: 8),
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
    decoration: BoxDecoration(
      color: const Color(0x2EFFFFFF),
      borderRadius: BorderRadius.circular(7),
      border: Border.all(color: const Color(0x1FFFFFFF)),
    ),
    child: Text.rich(
      TextSpan(
        children: [
          if (star) const TextSpan(text: '★ ', style: _starStyle),
          TextSpan(text: text),
        ],
      ),
      style: _chipStyle,
    ),
  );
}

const _pill = RoundedRectangleBorder(
  borderRadius: BorderRadius.all(Radius.circular(22)),
);

/// Watch at rest: as wide as when white, in the theme's glass.
const _watchGlass = ButtonStyle(
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(vertical: 14, horizontal: 28),
  ),
);

/// Watch while it is the white one: black on white, focused or not.
const _watchWhite = ButtonStyle(
  foregroundColor: WidgetStatePropertyAll(Colors.black),
  backgroundColor: WidgetStatePropertyAll(Colors.white),
  side: WidgetStatePropertyAll(BorderSide.none),
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(vertical: 14, horizontal: 28),
  ),
);

/// The theme's glass, round.
const _roundStyle = ButtonStyle(
  shape: WidgetStatePropertyAll(CircleBorder()),
  fixedSize: WidgetStatePropertyAll(Size.square(48)),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  padding: WidgetStatePropertyAll(EdgeInsets.zero),
);

const _shadow = BoxShadow(
  color: Color(0x99000000),
  blurRadius: 20,
  offset: Offset(0, 8),
);

/// Watch and the trailer button. The focused one grows to 1.06 over a shadow
/// (only the scale animates). One thing on screen is white: Watch, unless the
/// trailer button has focus, which then turns white and Watch glass.
class _Buttons extends StatefulWidget {
  final VoidCallback onOpen;
  final VoidCallback? onTrailer;
  final String label;
  const _Buttons({required this.onOpen, this.onTrailer, required this.label});

  @override
  State<_Buttons> createState() => _ButtonsState();
}

class _ButtonsState extends State<_Buttons> {
  /// 0 for Watch, 1 for the trailer button; null while neither has focus.
  int? _focus;

  void _focusChanged(int i, bool focused) => setState(() {
    if (focused) {
      _focus = i;
    } else if (_focus == i) {
      _focus = null;
    }
  });

  Widget _pop(int i, ShapeBorder shape, Widget button) => AnimatedScale(
    scale: _focus == i ? 1.06 : 1,
    duration: const Duration(milliseconds: 150),
    child: DecoratedBox(
      decoration: ShapeDecoration(
        shape: shape,
        shadows: _focus == i ? const [_shadow] : const [],
      ),
      child: button,
    ),
  );

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 12,
    children: [
      _pop(
        0,
        _pill,
        TextButton(
          onPressed: widget.onOpen,
          onFocusChange: (f) => _focusChanged(0, f),
          style: _focus == 1 ? _watchGlass : _watchWhite,
          child: Text(widget.label),
        ),
      ),
      if (widget.onTrailer case final onTrailer?)
        Tooltip(
          message: t('trailer'),
          child: _pop(
            1,
            const CircleBorder(),
            TextButton(
              onPressed: onTrailer,
              onFocusChange: (f) => _focusChanged(1, f),
              style: _roundStyle,
              child: const Icon(Icons.movie_outlined, size: 20),
            ),
          ),
        ),
    ],
  );
}

/// The title whole: in 44 px on up to two lines, else smaller, down to 24 px
/// on up to three; only a title too long even then ends in an ellipsis.
/// The title in a box two 32 px lines tall, the text on its floor: a short
/// title in one 44 px line (or 38), a longer one in two lines of 32, 28 or
/// 24. The box never changes height, so nothing under it moves, and the
/// block stays clear of the clock above and the dock below.
class _FitTitle extends StatelessWidget {
  final String title;
  final String? logoUrl;
  final String? logoAsset;
  final bool pending;
  const _FitTitle(
    this.title, {
    this.logoUrl,
    this.logoAsset,
    this.pending = false,
  });

  /// Font sizes tried in turn, with how many lines each may take.
  static const _sizes = [(44.0, 1), (38.0, 1), (32.0, 2), (28.0, 2), (24.0, 2)];
  static const _boxLine = 32.0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context);
      final height = scale.scale(_boxLine) * _titleStyle.height! * 2;
      // Measured in the font the Text will draw with (the theme's), not the
      // painter's default: that one is narrower and said long titles fit.
      final inherited = DefaultTextStyle.of(context).style;
      var style = _titleStyle;
      var lines = 1;
      if (box.maxWidth.isFinite) {
        for (final (size, max) in _sizes) {
          style = _titleStyle.copyWith(fontSize: size);
          lines = max;
          final painter = TextPainter(
            text: TextSpan(text: title, style: inherited.merge(style)),
            maxLines: max,
            textDirection: TextDirection.ltr,
            textScaler: scale,
          )..layout(maxWidth: box.maxWidth);
          final fits = !painter.didExceedMaxLines;
          painter.dispose();
          if (fits) break;
        }
      }
      final text = Text(
        title,
        maxLines: lines,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
      return SizedBox(
        height: height,
        child: Align(
          alignment: Alignment.bottomLeft,
          // The logo fills the box's height, no wider than most of the room.
          // Nothing shows while it is asked for or loads, then it fades in;
          // the text is for a title without one, or whose image fails.
          child: pending
              ? null
              : logoAsset != null
              ? Image.asset(
                  logoAsset!,
                  height: height,
                  width: box.maxWidth * 0.7,
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomLeft,
                  color: Colors.white,
                )
              : logoUrl == null
              ? text
              : Image(
                  image: DiskImage(logoUrl!),
                  key: ValueKey(logoUrl),
                  height: height,
                  width: box.maxWidth * 0.7,
                  fit: BoxFit.contain,
                  alignment: Alignment.bottomLeft,
                  frameBuilder: (_, image, frame, sync) => sync
                      ? image
                      : AnimatedOpacity(
                          opacity: frame == null ? 0 : 1,
                          duration: const Duration(milliseconds: 200),
                          child: image,
                        ),
                  errorBuilder: (_, _, _) => text,
                ),
        ),
      );
    },
  );
}
