import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../data/media.dart';
import '../disk_images.dart';
import 'input_brands.dart';

/// Under everything: what shows before the first backdrop, and with none;
/// also behind the first-run setup.
const backdropBase = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF0B0B0D), Color(0xFF1A1A22)],
  ),
);

// The mockup's two fades over the image: from the left, under the text, and
// from the bottom, under the rows. [BackdropImage] bakes them into each
// picture; on their own they only go over a game's or an input's colours.
const _fadeLeft = LinearGradient(
  colors: [Color(0xF20B0B0D), Color(0x8C0B0B0D), Color(0x000B0B0D)],
  stops: [0, 0.45, 0.7],
);
const _fadeUp = LinearGradient(
  begin: Alignment.topCenter,
  end: Alignment.bottomCenter,
  colors: [Color(0x000B0B0D), Color(0xFF0B0B0D)],
  stops: [0.55, 1],
);

/// How dark the backdrop goes under the rows.
const _dim = Color(0x8A000000);
const _dimTime = Duration(milliseconds: 200);

/// A game's backdrop: dark, from the home team's colour to the away team's
/// (when ESPN gives them).
BoxDecoration _gameBase(Game g) {
  Color tone(GameTeam t, Color none) {
    final rgb = int.tryParse(t.color ?? '', radix: 16);
    return rgb == null
        ? none
        : Color.lerp(Color(0xFF000000 | rgb), const Color(0xFF0B0B0D), 0.6)!;
  }

  return BoxDecoration(
    gradient: LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        tone(g.home, const Color(0xFF1A1A22)),
        tone(g.away, const Color(0xFF0B0B0D)),
      ],
    ),
  );
}

/// A backdrop's size once decoded: half of 1080p.
const _size = Size(960, 540);

/// A backdrop as the home draws it: the picture at [_size], covering it, with
/// the two fades baked in. One draw per frame then shows it, where the picture
/// and two full-screen gradients were three: the TV's GPU is what sets the
/// frame rate. Equal by its bytes, like [MemoryImage]: the key it has in
/// [imageCache].
@visibleForTesting
class BackdropImage extends ImageProvider<BackdropImage> {
  final Uint8List bytes;
  const BackdropImage(this.bytes);

  @override
  Future<BackdropImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    BackdropImage key,
    ImageDecoderCallback decode,
  ) => _OneFrame(_bake(decode));

  Future<ImageInfo> _bake(ImageDecoderCallback decode) async {
    final codec = await decode(
      await ui.ImmutableBuffer.fromUint8List(bytes),
      getTargetSize: (_, _) => ui.TargetImageSize(width: _size.width.round()),
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final picture = frame.image;
    final rect = Offset.zero & _size;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintImage(canvas: canvas, rect: rect, image: picture, fit: BoxFit.cover);
    canvas.drawRect(rect, Paint()..shader = _fadeLeft.createShader(rect));
    canvas.drawRect(rect, Paint()..shader = _fadeUp.createShader(rect));
    final baked = recorder.endRecording();
    try {
      // On the GPU, where it is drawn from: toImage() would read the pixels
      // back (37 ms on the TV) and upload them again.
      return ImageInfo(
        image: baked.toImageSync(_size.width.round(), _size.height.round()),
      );
    } finally {
      baked.dispose();
      picture.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is BackdropImage && other.bytes == bytes;

  @override
  int get hashCode => bytes.hashCode;
}

/// [OneFrameImageStreamCompleter], but a bake done after the stream was
/// disposed (evicted, or no one left listening) is dropped: setting it would
/// throw.
class _OneFrame extends ImageStreamCompleter {
  var _gone = false;

  _OneFrame(Future<ImageInfo> image) {
    image.then<void>(
      (info) => _gone ? info.dispose() : setImage(info),
      onError: (Object error, StackTrace stack) {
        if (_gone) return;
        reportError(
          context: ErrorDescription('baking a backdrop'),
          exception: error,
          stack: stack,
          silent: true,
        );
      },
    );
  }

  @override
  void onDisposed() {
    _gone = true;
    super.onDisposed();
  }
}

/// The provider of a backdrop's [bytes]: the key it has in [imageCache].
@visibleForTesting
ImageProvider backdropImage(Uint8List bytes) => BackdropImage(bytes);

/// Where the images come from; tests hand in their own bytes.
@visibleForTesting
var fetchBackdrop = DiskImages.bytes;

/// How long focus rests on a card before its backdrop is asked for: holding
/// an arrow passes many cards, and only the one it stops on needs a picture.
const _followDelay = Duration(milliseconds: 200);

/// The full-screen backdrop: the [focused] item's, else one of [rotation],
/// the next one every 10 s while the app is in the foreground. An image stays
/// up until the next one is in. [onShown] hears the item whose image is up,
/// null when there is none.
class Backdrop extends StatefulWidget {
  final ValueListenable<MediaItem?> focused;
  final List<MediaItem> rotation;
  final bool dimmed;
  final ValueChanged<MediaItem?> onShown;

  const Backdrop({
    super.key,
    required this.focused,
    required this.rotation,
    required this.dimmed,
    required this.onShown,
  });

  @override
  State<Backdrop> createState() => _BackdropState();
}

class _BackdropState extends State<Backdrop> {
  late final AppLifecycleListener _lifecycle;
  Timer? _timer;
  var _index = 0;

  /// Bumped when the app leaves the foreground: a new switcher holds only the
  /// current image, at full opacity, so the curtain's snapshot never catches a
  /// crossfade halfway.
  var _settle = 0;

  /// Image bytes by URL, for the rotation and the focused item only.
  final _bytes = <String, Uint8List>{};
  final _loading = <String>{};
  ({MediaItem item, Uint8List bytes})? _up;

  /// The fetch a focused card is waiting for (see [_followDelay]).
  Timer? _follow;

  @override
  void initState() {
    super.initState();
    widget.focused.addListener(_changed);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state == AppLifecycleState.resumed) {
          _play();
        } else {
          _pause();
          setState(() => _settle++);
        }
      },
    );
    _play();
    _sync();
  }

  @override
  void didUpdateWidget(Backdrop old) {
    super.didUpdateWidget(old);
    if (old.focused != widget.focused) {
      old.focused.removeListener(_changed);
      widget.focused.addListener(_changed);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.focused.removeListener(_changed);
    _lifecycle.dispose();
    _pause();
    _follow?.cancel();
    super.dispose();
  }

  void _changed() => setState(_sync);

  void _play() => _timer ??= Timer.periodic(
    const Duration(seconds: 10),
    (_) => setState(() {
      _index++;
      _sync();
    }),
  );

  void _pause() {
    _timer?.cancel();
    _timer = null;
  }

  Set<String> get _wanted => {
    for (final item in widget.rotation) ?item.backdropUrl,
    ?widget.focused.value?.backdropUrl,
  };

  /// Puts up the image of the item due on screen when its bytes are here;
  /// otherwise asks for them and leaves what is up meanwhile. A focused item
  /// without a backdrop shows none; one that focus has only just reached
  /// waits [_followDelay] first.
  void _sync() {
    final wanted = _wanted;
    _bytes.removeWhere((url, _) => !wanted.contains(url));
    final rotation = widget.rotation;
    final focused = widget.focused.value;
    final item =
        focused ??
        (rotation.isEmpty ? null : rotation[_index % rotation.length]);
    final url = item?.backdropUrl;
    _follow?.cancel();
    if (url == null) return _put(null);
    final bytes = _bytes[url];
    if (bytes != null) {
      _put((item: item!, bytes: bytes));
    } else if (focused == null) {
      _fetch(url);
    } else {
      _follow = Timer(_followDelay, () {
        if (mounted && _wanted.contains(url)) _fetch(url);
      });
    }
  }

  void _put(({MediaItem item, Uint8List bytes})? up) {
    if (up == _up) return;
    // Only the image on screen stays decoded: the raw bytes are the cache, so
    // a re-show decodes again. The fade-out keeps its own stream meanwhile.
    if (_up case final old? when old.bytes != up?.bytes) {
      backdropImage(old.bytes).evict();
    }
    _up = up;
    // After the frame that shows it, so the listener never runs in a build.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onShown(up?.item);
    });
  }

  /// A failed fetch changes nothing; the item asks again when it is next due.
  Future<void> _fetch(String url) async {
    if (!_loading.add(url)) return;
    try {
      final bytes = await fetchBackdrop(Uri.parse(url));
      if (mounted && _wanted.contains(url)) {
        setState(() {
          _bytes[url] = bytes;
          _sync();
        });
      }
    } catch (_) {}
    _loading.remove(url);
  }

  @override
  Widget build(BuildContext context) {
    final up = _up;
    final focused = widget.focused.value;
    return Stack(
      fit: StackFit.expand,
      children: [
        // Nothing under a backdrop: it covers the screen, and every
        // full-screen draw counts on the TV's GPU. Without one, the base, a
        // game's or a console's colours, and the fades and the dim over them.
        if (up == null) ...[
          const DecoratedBox(decoration: backdropBase),
          if (focused?.game case final game?)
            DecoratedBox(decoration: _gameBase(game)),
          // A known console's input: its colours, its maker's symbol faint on
          // the right.
          if (focused case final item? when item.type == MediaType.input)
            if (InputBrand.of(item.genre) case final brand?)
              DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topRight,
                    end: Alignment.bottomLeft,
                    colors: brand.gradient,
                  ),
                ),
                child: Align(
                  alignment: const Alignment(0.7, -0.35),
                  child: FractionallySizedBox(
                    heightFactor: 0.5,
                    child: Image.asset(
                      brand.mark,
                      color: Colors.white,
                      opacity: const AlwaysStoppedAnimation(0.14),
                    ),
                  ),
                ),
              ),
        ],
        // The dim is a colour on the picture's own draw, not a layer over it.
        TweenAnimationBuilder<double>(
          tween: Tween(end: widget.dimmed ? 1 : 0),
          duration: _dimTime,
          builder: (_, dim, _) => AnimatedSwitcher(
            key: ValueKey(_settle),
            duration: const Duration(milliseconds: 600),
            child: switch (up) {
              null => const SizedBox.shrink(),
              (:final item, :final bytes) => Image(
                image: backdropImage(bytes),
                key: ValueKey(item.backdropUrl),
                fit: BoxFit.cover,
                gaplessPlayback: true,
                width: double.infinity,
                height: double.infinity,
                color: dim == 0 ? null : _dim.withValues(alpha: _dim.a * dim),
                colorBlendMode: BlendMode.srcATop,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            },
          ),
        ),
        if (up == null) ...[
          const DecoratedBox(decoration: BoxDecoration(gradient: _fadeLeft)),
          const DecoratedBox(decoration: BoxDecoration(gradient: _fadeUp)),
          AnimatedOpacity(
            opacity: widget.dimmed ? 1 : 0,
            duration: _dimTime,
            child: const ColoredBox(color: _dim),
          ),
        ],
      ],
    );
  }
}
