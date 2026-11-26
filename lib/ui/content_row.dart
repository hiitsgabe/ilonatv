import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';

import '../data/media.dart';
import '../data/sports.dart';
import '../data/tmdb.dart';
import '../disk_images.dart';
import '../hold_to_trailer.dart';
import '../i18n.dart';
import 'glass.dart';
import 'input_brands.dart';
import 'rows_traversal.dart';

/// The card focus goes back to in a row of [length] cards that last had it at
/// [remembered]: that one, or the nearest end when the row got shorter.
int clampFocus(int remembered, int length) =>
    length == 0 ? 0 : remembered.clamp(0, length - 1);

final _okKeys = {
  LogicalKeyboardKey.select,
  LogicalKeyboardKey.enter,
  LogicalKeyboardKey.numpadEnter,
  LogicalKeyboardKey.gameButtonA,
};

const _radius = BorderRadius.all(Radius.circular(14));
const _titleStyle = TextStyle(
  fontSize: 20,
  fontWeight: FontWeight.w600,
  color: Color(0xE6FFFFFF),
);
const _boxStyle = TextStyle(fontSize: 12, color: Color(0xD9FFFFFF));
const _pillStyle = TextStyle(fontSize: 14, color: Color(0xE6FFFFFF));
const _abbrStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w700,
  color: Color(0xE6FFFFFF),
);
const _liveStyle = TextStyle(
  fontSize: 12,
  fontWeight: FontWeight.w700,
  color: Color(0xFFFF5A5F),
);
const _filterStyle = TextStyle(fontSize: 16, color: Color(0xD9FFFFFF));
const _genreStyle = TextStyle(
  fontSize: 13,
  fontWeight: FontWeight.w600,
  color: Color(0xE6FFFFFF),
);

/// An icon per JustWatch genre code; All and an unknown code get the
/// generic one.
const _genreIcons = {
  'act': Icons.bolt,
  'ani': Icons.animation,
  'cmy': Icons.sentiment_very_satisfied,
  'crm': Icons.local_police,
  'doc': Icons.videocam,
  'drm': Icons.theater_comedy,
  'eur': Icons.euro,
  'fml': Icons.family_restroom,
  'fnt': Icons.auto_awesome,
  'hrr': Icons.dark_mode,
  'hst': Icons.account_balance,
  'msc': Icons.music_note,
  'rly': Icons.live_tv,
  'rma': Icons.favorite,
  'scf': Icons.rocket_launch,
  'spt': Icons.sports_soccer,
  'trl': Icons.search,
  'war': Icons.military_tech,
  'wsn': Icons.landscape,
};
const _chevron = Color(0x99FFFFFF);

/// The streaming services a row can show one of, after All (null). Left on
/// the row's first card brings up the card that picks one with Up and Down.
class RowFilter {
  final List<WatchProvider> options;

  /// A service's id; null is All.
  final int? selected;
  final ValueChanged<int?> onChanged;

  /// The genres a second card, left of the first, picks from after All;
  /// with none, Left on the service card does nothing.
  final List<Genre> genres;

  /// A genre's code; null is All.
  final String? genre;
  final ValueChanged<String?>? onGenre;

  const RowFilter({
    required this.options,
    required this.selected,
    required this.onChanged,
    this.genres = const [],
    this.genre,
    this.onGenre,
  });
}

/// A titled row of posters (2:3), or of video thumbs (16:9) when [wide]. OK on
/// a card calls [onOpen] on a release within a second. Held on, when
/// [trailerKey] is there, the card asks it for the trailer's key and counts
/// down; at four seconds, or when the key comes after that, [onTrailer] gets
/// the key. No trailer, or a failed ask, ends the countdown (see
/// [HoldToTrailer]). [onFocus] hears each card that gets focus, and null when focus leaves
/// the row; when it comes back, focus lands on the card it left. The home
/// brings focus in from another row with [ContentRowState.focusNear]. With a
/// [filter], Left on the first card brings up the filter card in front of it,
/// there while it has focus; [onFocus] does not hear it.
class ContentRow extends StatefulWidget {
  final String title;
  final List<MediaItem> items;
  final bool wide;
  final RowFilter? filter;

  /// Off for a row far from the focused one, which is off screen: its cards
  /// keep their grey box and give their images' GPU memory back.
  final bool images;
  final ValueChanged<MediaItem?> onFocus;
  final ValueChanged<MediaItem> onOpen;
  final Future<String?> Function(MediaItem)? trailerKey;
  final ValueChanged<String>? onTrailer;

  const ContentRow({
    super.key,
    required this.title,
    required this.items,
    this.wide = false,
    this.images = true,
    required this.onFocus,
    required this.onOpen,
    this.trailerKey,
    this.onTrailer,
    this.filter,
  });

  @override
  State<ContentRow> createState() => ContentRowState();
}

class ContentRowState extends State<ContentRow> {
  /// One per card index built so far, so never more than the row's length.
  final _nodes = <int, FocusNode>{};
  final _scroll = ScrollController();

  /// A card's slot in the list, set at build.
  var _extent = 1.0;

  /// The card that had focus last; null until one has had it.
  int? _remembered;
  var _inside = false;

  /// The card focus is being sent on to; the one it passes through on the way
  /// is not reported.
  int? _sending;

  /// The service card is up, in front of the first title.
  var _filtering = false;
  final _filterNode = FocusNode();

  /// The genre card is up, left of the service card.
  var _genreFiltering = false;
  final _genreNode = FocusNode();

  int get _cardsUp => (_filtering ? 1 : 0) + (_genreFiltering ? 1 : 0);

  /// OK on the focused card; a focus change cancels it, so a release counts
  /// only on the card the press began on.
  final _hold = HoldToTrailer();
  final _held = Stopwatch();

  /// Only while OK is down on a card with a trailer.
  Timer? _ticks;

  /// Android pauses Elimor without taking focus from the card, and the
  /// release may never come: the hold ends there.
  late final AppLifecycleListener _lifecycle;

  void _stopHold() {
    _ticks?.cancel();
    _ticks = null;
    _hold.cancel();
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onInactive: () {
        final counting = _hold.phase == HoldPhase.countdown;
        _stopHold();
        if (counting) setState(() {}); // the countdown goes
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _ticks?.cancel();
    _scroll.dispose();
    _filterNode.dispose();
    _genreNode.dispose();
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  /// Focus coming in from the row above or below: on the card this row had
  /// last, else on the card under the screen x [x] (the one the eye is on),
  /// else the first. A remembered card that is no longer built (the row was
  /// scrolled far since) gives way to the one under [x] too.
  void focusNear(double x) {
    final n = widget.items.length;
    if (n == 0) return;
    int under() {
      final box = context.findRenderObject() as RenderBox?;
      final left = box?.localToGlobal(Offset.zero).dx ?? 0;
      final w = MediaQuery.sizeOf(context).width;
      final offset = _scroll.hasClients ? _scroll.offset : 0.0;
      return ((x - left + offset - kRowLeadIn * w) / _extent).floor().clamp(
        0,
        n - 1,
      );
    }

    var target = _remembered == null ? under() : clampFocus(_remembered!, n);
    var node = _nodes[target];
    if (node == null || !(node.context?.mounted ?? false)) {
      target = under();
      node = _nodes[target];
    }
    if (node == null) return;
    _sending = target;
    focusInRow(node);
  }

  // A refresh can put another item under the focused card, or empty the row
  // (focus has then left it). The home hears it after the frame, so its
  // listener never runs in a build.
  @override
  void didUpdateWidget(ContentRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    final last = _remembered;
    if (!_inside || last == null) return;
    MediaItem? item;
    if (widget.items.isEmpty) {
      // Under the filter card focus is still here, on nothing to report.
      if (_filtering) return;
      _inside = false;
    } else {
      final i = clampFocus(last, widget.items.length);
      if (widget.items[i].key == oldWidget.items.elementAtOrNull(last)?.key) {
        return;
      }
      _remembered = i;
      item = widget.items[i];
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onFocus(item);
    });
  }

  void _rowFocusChanged(bool focused) {
    if (focused == _inside) return;
    _inside = focused;
    if (!focused) {
      widget.onFocus(null);
      return;
    }
    // Arrows bring focus in at the card nearest the one it left elsewhere;
    // send it on to the card this row had last.
    final last = _remembered;
    if (last == null) return;
    final target = clampFocus(last, widget.items.length);
    final node = _nodes[target];
    if (node != null &&
        (node.context?.mounted ?? false) &&
        !node.hasPrimaryFocus) {
      _sending = target;
      // With its scroll: the arrow's own card started one, to itself.
      focusInRow(node);
    }
  }

  void _cardFocusChanged(int i, bool focused) {
    // The card that lost focus rebuilds without its countdown.
    _stopHold();
    if (!focused || _sending != null && _sending != i) return;
    _sending = null;
    _remembered = i;
    widget.onFocus(widget.items[i]);
  }

  /// Brings the filter card up, focus on it once it is built and the row at
  /// its start, or takes it down, focus back on the first title. Focus moves
  /// after the frame: the card's node is only in the tree then, and the
  /// unfocus of a node the rebuild drops no longer gets in the way.
  void _showFilter(bool up) {
    setState(() => _filtering = up);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _filtering != up) return;
      if (up) {
        _filterNode.requestFocus();
        if (_scroll.hasClients) _scroll.jumpTo(0);
      } else if (_nodes[0] case final node?) {
        focusInRow(node);
      }
    });
  }

  /// Brings the genre card up, left of the service card, or takes it down,
  /// focus back on the service card; after the frame, as [_showFilter].
  void _showGenre(bool up) {
    setState(() => _genreFiltering = up);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _genreFiltering != up) return;
      (up ? _genreNode : _filterNode).requestFocus();
      if (up && _scroll.hasClients) _scroll.jumpTo(0);
    });
  }

  /// The choice before or after [current] in [choices], clamped at the
  /// ends, to [pick] when it differs; one no longer offered counts as the
  /// first (All).
  static void _step<T>(
    List<T?> choices,
    T? current,
    bool down,
    void Function(T?) pick,
  ) {
    final last = choices.length - 1;
    final at = choices.indexOf(current).clamp(0, last);
    final to = (at + (down ? 1 : -1)).clamp(0, last);
    if (to != at) pick(choices[to]);
  }

  KeyEventResult _filterKey(KeyEvent e) {
    final k = e.logicalKey;
    final filter = widget.filter!;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      // Up and Down pick, and never leave the row.
      if (e is! KeyUpEvent) {
        _step(
          [null, for (final p in filter.options) p.id],
          filter.selected,
          k == LogicalKeyboardKey.arrowDown,
          filter.onChanged,
        );
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      // Back to the first title, when the row has one.
      if (e is KeyDownEvent && widget.items.isNotEmpty) _showFilter(false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      // With genres, their card comes up in front; else nothing further.
      if (e is KeyDownEvent && filter.genres.isNotEmpty) _showGenre(true);
      return KeyEventResult.handled;
    }
    if (_okKeys.contains(k)) return KeyEventResult.handled;
    return KeyEventResult.ignored;
  }

  KeyEventResult _genreKey(KeyEvent e) {
    final k = e.logicalKey;
    final filter = widget.filter!;
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      if (e is! KeyUpEvent) {
        _step(
          [null, for (final g in filter.genres) g.code],
          filter.genre,
          k == LogicalKeyboardKey.arrowDown,
          (code) => filter.onGenre?.call(code),
        );
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      if (e is KeyDownEvent) _showGenre(false);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft || _okKeys.contains(k)) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _onKey(int i, KeyEvent e) {
    final k = e.logicalKey;
    // At an end there is no card further, and the arrow must not carry focus
    // into another row that has one; at the start, a filter's card comes up.
    if (k == LogicalKeyboardKey.arrowLeft && i == 0) {
      if (widget.filter != null && e is KeyDownEvent) _showFilter(true);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight && i == widget.items.length - 1) {
      return KeyEventResult.handled;
    }
    if (!_okKeys.contains(k)) return KeyEventResult.ignored;
    // A repeat is ignored: the stopwatch tells how long OK has been down.
    if (e is KeyDownEvent) {
      _ticks?.cancel();
      _hold.down();
      _held
        ..reset()
        ..start();
      final item = widget.items[i];
      final trailerKey = widget.trailerKey;
      if (trailerKey != null) {
        _ticks = Timer.periodic(
          const Duration(milliseconds: 250),
          (_) => _tick(item, trailerKey),
        );
      }
    } else if (e is KeyUpEvent) {
      final counting = _hold.phase == HoldPhase.countdown;
      final outcome = _hold.up(_held.elapsed);
      _stopHold();
      if (counting) setState(() {}); // the countdown goes
      if (outcome == HoldOutcome.open) widget.onOpen(widget.items[i]);
    }
    return KeyEventResult.handled;
  }

  void _tick(MediaItem item, Future<String?> Function(MediaItem) trailerKey) {
    final before = (_hold.phase, _hold.secondsLeft);
    _show(before, _hold.tick(_held.elapsed));
    // The countdown just began: its key is asked for, once per press.
    if (before.$1 == HoldPhase.pressed && _hold.phase == HoldPhase.countdown) {
      final hold = _hold.hold;
      trailerKey(item).then<String?>((k) => k, onError: (_) => null).then((k) {
        // Gone, or a press that has ended: [HoldToTrailer.answer] drops it.
        if (!mounted) return;
        _show((_hold.phase, _hold.secondsLeft), _hold.answer(hold, k));
      });
    }
  }

  /// Fires, or stops ticking once nothing more can come, and repaints the
  /// countdown when it changed from [before].
  void _show((HoldPhase, int) before, HoldPhase phase) {
    if (phase == HoldPhase.fired || phase == HoldPhase.noTrailer) {
      _ticks?.cancel();
      _ticks = null;
    }
    if (HoldToTrailer.firedNow(before.$1, phase)) {
      widget.onTrailer?.call(_hold.key!);
      _hold.cancel();
    }
    if ((phase, _hold.secondsLeft) != before) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final ratio = widget.wide ? 16 / 9 : 2 / 3;
    final cardWidth = (widget.wide ? 0.155 : 0.092) * w;
    final gap = 0.014 * w;
    _extent = cardWidth + gap;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(left: 0.04 * w),
          child: Text(widget.title, style: _titleStyle),
        ),
        const SizedBox(height: 12),
        // The cards alone: the big title above the rows names the focused one,
        // so nothing is written under a card.
        SizedBox(
          height: cardWidth / ratio,
          child: FocusTraversalGroup(
            policy: rowsTraversalPolicy(),
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: _rowFocusChanged,
              child: ListView.builder(
                controller: _scroll,
                scrollDirection: Axis.horizontal,
                // The focused card grows a little past the list's bounds.
                clipBehavior: Clip.none,
                addAutomaticKeepAlives: false,
                scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                padding: EdgeInsets.only(left: kRowLeadIn * w),
                itemExtent: cardWidth + gap,
                // The filter cards, up, take the first slots; an empty row
                // keeps them, so another pick can be made.
                itemCount: widget.items.length + _cardsUp,
                itemBuilder: (context, i) => i >= _cardsUp
                    ? _card(i - _cardsUp, ratio, gap)
                    : i == 0 && _genreFiltering
                    ? _genreCard(ratio, gap)
                    : _filterCard(ratio, gap),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The service card: the chosen service's logo (its name without one, or
  /// All) between the chevrons that change it.
  Widget _filterCard(double ratio, double gap) {
    final filter = widget.filter!;
    final service = filter.options
        .where((p) => p.id == filter.selected)
        .firstOrNull;
    return _pickerCard(
      key: const ValueKey('filter'),
      node: _filterNode,
      // It goes with focus, except to the genre card, behind which it stays.
      onFocusChange: (focused) {
        if (!focused && _filtering && !_genreFiltering) {
          setState(() => _filtering = false);
        }
      },
      onKey: _filterKey,
      ratio: ratio,
      gap: gap,
      face: service?.logoUrl != null
          ? FractionallySizedBox(
              widthFactor: 0.6,
              heightFactor: 0.6,
              child: Image(
                image: DiskImage(service!.logoUrl!),
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => _pickerText(service.name),
              ),
            )
          : _pickerText(service?.name ?? t('allProviders')),
    );
  }

  /// The genre card: the chosen genre's name, or All, between the chevrons.
  Widget _genreCard(double ratio, double gap) {
    final filter = widget.filter!;
    final genre = filter.genres
        .where((g) => g.code == filter.genre)
        .firstOrNull;
    return _pickerCard(
      key: const ValueKey('genre'),
      node: _genreNode,
      // It goes with focus, and the service card with it unless focus went
      // there.
      onFocusChange: (focused) {
        if (!focused && _genreFiltering) {
          setState(() {
            _genreFiltering = false;
            if (!_filterNode.hasFocus) _filtering = false;
          });
        }
      },
      onKey: _genreKey,
      ratio: ratio,
      gap: gap,
      // An icon over the name, the name on one line; both shrink to fit.
      face: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _genreIcons[genre?.code] ?? Icons.category,
              size: 34,
              color: const Color(0xE6FFFFFF),
            ),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                genre?.name ?? t('allProviders'),
                maxLines: 1,
                softWrap: false,
                style: _genreStyle,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pickerText(String text) =>
      Text(text, textAlign: TextAlign.center, style: _filterStyle);

  /// A picker card: glass, [face] between the chevrons that change it,
  /// lifted with focus like the title cards.
  Widget _pickerCard({
    required Key key,
    required FocusNode node,
    required ValueChanged<bool> onFocusChange,
    required KeyEventResult Function(KeyEvent) onKey,
    required double ratio,
    required double gap,
    required Widget face,
  }) => Focus(
    key: key,
    focusNode: node,
    onFocusChange: onFocusChange,
    onKeyEvent: (_, e) => onKey(e),
    child: Padding(
      padding: EdgeInsets.symmetric(horizontal: gap / 2),
      child: Builder(
        builder: (context) => RepaintBoundary(
          child: FocusLift(
            focused: Focus.of(context).hasPrimaryFocus,
            radius: 14,
            child: AspectRatio(
              aspectRatio: ratio,
              child: Glass(
                radius: 14,
                padding: const EdgeInsets.all(6),
                child: Column(
                  children: [
                    const Icon(
                      Icons.keyboard_arrow_up,
                      size: 20,
                      color: _chevron,
                    ),
                    Expanded(child: Center(child: face)),
                    const Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: _chevron,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _card(int i, double ratio, double gap) {
    final item = widget.items[i];
    final url = item.posterUrl;
    return Focus(
      focusNode: _nodes[i] ??= FocusNode(),
      onFocusChange: (focused) => _cardFocusChanged(i, focused),
      onKeyEvent: (_, e) => _onKey(i, e),
      // Half the gap on each side, inside the focus: scrolled to an edge, the
      // focused card keeps room to grow.
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: gap / 2),
        child: Builder(
          builder: (context) {
            final focused = Focus.of(context).hasPrimaryFocus;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // A lift repaints this card only.
                RepaintBoundary(
                  child: FocusLift(
                    focused: focused,
                    radius: 14,
                    child: AspectRatio(
                      aspectRatio: ratio,
                      child: item.game != null
                          ? _GameFace(item.game!)
                          : item.type == MediaType.input
                          ? _InputFace(item.title, item.genre)
                          : ClipRRect(
                              borderRadius: _radius,
                              // The grey box with the title shows until the image
                              // is in, and stays when there is none. Not under
                              // the image once it is in: the TV's GPU draws
                              // every card on every frame of a move.
                              child: Stack(
                                fit: StackFit.expand,
                                children: [
                                  if (url != null && widget.images)
                                    Image(
                                      image: ResizeImage(
                                        DiskImage(url),
                                        width: widget.wide ? 300 : 192,
                                      ),
                                      fit: BoxFit.cover,
                                      frameBuilder: (_, image, frame, _) =>
                                          frame == null
                                          ? _TitleBox(item.title)
                                          : image,
                                      errorBuilder: (_, _, _) =>
                                          _TitleBox(item.title),
                                    )
                                  else
                                    _TitleBox(item.title),
                                  // How much was watched: white on a 30 % white
                                  // track, inside the card, 4 px above its edge.
                                  if (item.progress case final p?)
                                    Positioned(
                                      key: const ValueKey('progress'),
                                      left: 8,
                                      right: 8,
                                      bottom: 4,
                                      height: 3,
                                      child: ColoredBox(
                                        color: const Color(0x4DFFFFFF),
                                        child: FractionallySizedBox(
                                          alignment: Alignment.centerLeft,
                                          widthFactor: p.clamp(0, 1),
                                          child: const ColoredBox(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (focused &&
                                      _hold.phase == HoldPhase.countdown)
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 12,
                                      child: Center(
                                        child: DecoratedBox(
                                          decoration: const BoxDecoration(
                                            color: Color(0xB3000000),
                                            borderRadius: BorderRadius.all(
                                              Radius.circular(12),
                                            ),
                                          ),
                                          child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 10,
                                              vertical: 4,
                                            ),
                                            child: Text(
                                              '${t('trailer')} ${_hold.secondsLeft}',
                                              style: _pillStyle,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A card's grey box with its title: what shows until the picture is in, and
/// what stays when there is none.
class _TitleBox extends StatelessWidget {
  final String title;
  const _TitleBox(this.title);

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: const Color(0xFF2A2A2E),
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Text(
          title,
          textAlign: TextAlign.center,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: _boxStyle,
        ),
      ),
    ),
  );
}

/// An input's card: glass, an HDMI plug over the input's [label].
/// An input's card. One whose HDMI-CEC name names a console it knows shows
/// that console's wordmark over its brand colours; the others, the HDMI icon
/// and the port's label on glass.
class _InputFace extends StatelessWidget {
  final String label;
  final String device;
  const _InputFace(this.label, this.device);

  @override
  Widget build(BuildContext context) {
    final brand = InputBrand.of(device);
    if (brand != null) {
      return ClipRRect(
        borderRadius: _radius,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: brand.gradient,
            ),
          ),
          child: Center(
            child: FractionallySizedBox(
              widthFactor: brand.width,
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Colors.white,
                  BlendMode.srcIn,
                ),
                child: Image.asset(brand.asset, fit: BoxFit.contain),
              ),
            ),
          ),
        ),
      );
    }
    return Glass(
      radius: 14,
      padding: const EdgeInsets.all(6),
      child: Center(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.settings_input_hdmi,
                size: 34,
                color: Color(0xE6FFFFFF),
              ),
              const SizedBox(height: 6),
              Text(label, style: _abbrStyle),
            ],
          ),
        ),
      ),
    );
  }
}

/// A game's card: glass, the two logos over their abbreviations (home on the
/// left), and under them when it is, the live score or the final one.
class _GameFace extends StatelessWidget {
  final Game game;
  const _GameFace(this.game);

  Widget _side(GameTeam team) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      SizedBox.square(
        dimension: 30,
        child: team.logo == null
            ? null
            : Image(
                image: ResizeImage(DiskImage(team.logo!), width: 96),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
      ),
      const SizedBox(height: 2),
      Text(team.abbr, style: _abbrStyle),
    ],
  );

  @override
  Widget build(BuildContext context) => Glass(
    radius: 14,
    padding: const EdgeInsets.all(6),
    // Shrinks, rather than overflow, with a large font or a long status.
    child: Center(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 16,
              children: [
                _side(game.home),
                const Text('×', style: _boxStyle),
                _side(game.away),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              gameStatus(game, DateTime.now()),
              style: game.live ? _liveStyle : _boxStyle,
            ),
          ],
        ),
      ),
    ),
  );
}
