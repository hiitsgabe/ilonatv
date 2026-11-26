import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../companion/pairing.dart';
import '../data/inputs.dart';
import '../data/media.dart';
import '../device.dart';
import '../data/tmdb.dart';
import '../host.dart';
import '../i18n.dart';
import '../providers.dart';
import '../settings.dart';
import '../sources.dart';
import '../store.dart';
import 'app_row.dart';
import 'apps_screen.dart';
import 'backdrop.dart';
import 'input_brands.dart';
import 'clock.dart';
import 'content_row.dart';
import 'glass.dart';
import 'highlight.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'weather_line.dart';

/// How long the rows take to move, and to fade and dim with it.
const _moveTime = Duration(milliseconds: 200);

/// The rows of video thumbs, of games and of inputs: 16:9 cards, and no
/// trailer.
const _wideRows = {'inputs', 'youtubeContinue', 'youtube', 'games'};

/// Left at the [first] control of a row or Right at its [last] stays put: the
/// arrow would otherwise carry focus to whatever is nearest that way, in a
/// content row.
KeyEventResult _ends(KeyEvent e, {required bool first, required bool last}) {
  final k = e.logicalKey;
  return k == LogicalKeyboardKey.arrowLeft && first ||
          k == LogicalKeyboardKey.arrowRight && last
      ? KeyEventResult.handled
      : KeyEventResult.ignored;
}

class HomeScreen extends StatefulWidget {
  final Settings settings;
  final Sources sources;

  /// Where the app list and the tiles' icons of the last run are kept, so the
  /// row is whole from its first frame; none in tests.
  final Store? store;

  /// That app list as `main` read it before the first frame (the store's
  /// `apps` entry), so the dock is in the first frame; null to read it here.
  final Map<String, dynamic>? cachedApps;
  final Pairing pairing;
  const HomeScreen(
    this.settings,
    this.sources, {
    super.key,
    required this.pairing,
    this.store,
    this.cachedApps,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// Installed apps by package; null until `listApps` first answers, and the
  /// row waits for it.
  Map<String, InstalledApp>? _apps;
  // A null value is an app with no icon. The store's icons from the last run
  // come first; Android's are asked once per run ([_fetched]) and replace
  // them when they changed.
  final _icons = <String, Uint8List?>{};
  final _fetched = <String>{};
  late final AppLifecycleListener _lifecycle;

  /// The TV's HDMI inputs with something on; asked on start, on every resume
  /// and when Android says they changed.
  List<MediaItem> _inputs = const [];

  /// The card that has focus; the backdrop and the highlight follow it.
  final _focused = ValueNotifier<MediaItem?>(null);

  /// The item whose backdrop is up: the rotation's while no card has focus.
  final _shown = ValueNotifier<MediaItem?>(null);

  /// The content row with focus, by its title key: it sits at the bottom,
  /// under the highlight, and what is above it slides out. Null while focus is
  /// on the app row or the highlight. A notifier, like the other marks of
  /// where focus is: a move rebuilds only what follows it (a row's images,
  /// the backdrop's dim, the hint), never the home with its hundred cards,
  /// which cost the TV 30 ms a key.
  final _row = ValueNotifier<String?>(null);

  /// Each row's "show your images" switch, by row key, flipped by
  /// [_rowChanged]: a row listens to its own, so a move rebuilds the rows
  /// whose switch turned, not all of them.
  final _rowImages = <String, ValueNotifier<bool>>{};
  final _rowStates = <String, GlobalKey<ContentRowState>>{};
  List<String> _rowKeys = const [];
  final _scroll = ScrollController();

  /// Around the app row, to tell when focus comes back to it.
  final _appRowFocus = FocusNode(canRequestFocus: false, skipTraversal: true);

  /// The magnifier and the gear in the corner pill; each keeps focus while
  /// what it opened is up, so Back lands on it.
  final _searchFocus = FocusNode();
  final _gearFocus = FocusNode();

  /// Focus is in the app row: the "⌃" over the dock shows.
  final _onApps = ValueNotifier(false);

  /// Focus is in the corner pill, which lights up.
  final _onPill = ValueNotifier(false);

  /// Whether the device has a network, for the pill's Wi-Fi icon.
  var _online = true;
  Timer? _netTimer;

  /// Around the banner's buttons.
  final _bannerFocus = FocusNode(canRequestFocus: false, skipTraversal: true);

  bool get _canSearch =>
      widget.sources.tmdb.error != TmdbError.noKey &&
      widget.settings.tmdbKey.isNotEmpty;

  List<AppTile> get _tiles => widget.settings.visibleTiles({...?_apps?.keys});

  @override
  void initState() {
    super.initState();
    _apps = _cachedApps(widget.cachedApps);
    widget.settings.addListener(_settingsChanged);
    _lifecycle = AppLifecycleListener(
      onResume: () {
        _loadApps();
        _loadInputs();
        _watchNet();
      },
      onPause: () => _netTimer?.cancel(),
    );
    _row.addListener(_rowChanged);
    _loadCached();
    _loadApps();
    _watchNet();
    Host.onInputsChanged = _loadInputs;
    Host.onGoHome = _goHome;
    _loadInputs();
  }

  /// Rows show their images only next to the focused one (the first row
  /// counts as next to the app row): every row stays built for the D-pad,
  /// and a row two away is off screen.
  bool _showsImages(int i, int at) => (i - at).abs() <= Device.rowWindow;

  void _rowChanged() {
    final at = _rowKeys.indexOf(_row.value ?? '');
    for (final (i, key) in _rowKeys.indexed) {
      _rowImages[key]?.value = _showsImages(i, at);
    }
  }

  /// The store's `apps` entry as the home's map; null for none, or one that
  /// does not read.
  static Map<String, InstalledApp>? _cachedApps(Map<String, dynamic>? cached) {
    if (cached == null) return null;
    try {
      return {
        for (final a in cached['apps'] as List)
          InstalledApp.fromJson(a).package: InstalledApp.fromJson(a),
      };
    } catch (_) {
      return null;
    }
  }

  /// The apps and the tiles' icons as the last run saw them, so the row is
  /// whole from its first frame; `listApps` and `appIcon` then replace what
  /// changed. A cache that will not read is nothing.
  Future<void> _loadCached() async {
    final store = widget.store;
    if (store == null) return;
    try {
      if (_apps == null) {
        final apps = _cachedApps(await store.read('apps'));
        if (!mounted) return;
        if (apps != null && _apps == null) setState(() => _apps = apps);
      }
      for (final tile in widget.settings.tiles) {
        if (tile.icon != 'app' || _icons.containsKey(tile.package)) continue;
        final png = await store.readBytes('icon-${tile.package}.png');
        if (!mounted) return;
        if (png != null && !_icons.containsKey(tile.package)) {
          setState(() => _icons[tile.package] = png);
        }
      }
    } catch (_) {}
  }

  /// Home: whatever is open closes, the rows come down and focus lands on the
  /// first app, at once rather than animated: Ilona TV is coming back from
  /// behind the curtain or another app, and its first frame should already
  /// be the top.
  void _goHome() {
    Navigator.of(context).popUntil((r) => r.isFirst);
    // Home starts the rows over: no service, no genre.
    final s = widget.settings;
    if (s.rowProviders.isNotEmpty || s.rowGenres.isNotEmpty) {
      s.rowProviders.clear();
      s.rowGenres.clear();
      s.save().ignore(); // the home rebuilds on it
    }
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _appRowFocus.traversalDescendants.firstOrNull?.requestFocus();
  }

  Future<void> _loadInputs() async {
    final inputs = await loadInputs();
    if (!mounted) return;
    // The row goes with focus in it: focus goes to the apps, not nowhere.
    if (inputs.isEmpty && _row.value == 'inputs') {
      _appRowFocus.traversalDescendants.firstOrNull?.requestFocus();
    }
    setState(() => _inputs = inputs);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    Host.onInputsChanged = null;
    _netTimer?.cancel();
    widget.settings.removeListener(_settingsChanged);
    _focused.dispose();
    _shown.dispose();
    _row.dispose();
    for (final n in _rowImages.values) {
      n.dispose();
    }
    _onApps.dispose();
    _onPill.dispose();
    _scroll.dispose();
    _appRowFocus.dispose();
    _searchFocus.dispose();
    _gearFocus.dispose();
    _bannerFocus.dispose();
    super.dispose();
  }

  /// Asked again on every resume, so apps installed or removed outside Ilona TV
  /// show up. A failed call keeps the last list (empty the first time) and the
  /// next resume retries. Icons already fetched are kept. A good list goes to
  /// the store for the next start.
  Future<void> _loadApps() async {
    final apps = await Host.listApps().then<List<InstalledApp>?>(
      (a) => a,
      onError: (_) => null,
    );
    if (!mounted) return;
    setState(
      () => _apps = apps == null
          ? (_apps ?? {})
          : {for (final a in apps) a.package: a},
    );
    _loadIcons();
    if (apps != null) {
      widget.store?.write('apps', {
        'apps': [for (final a in apps) a.toJson()],
      }).ignore();
    }
  }

  /// Checks the network now and every 30 s, while Ilona TV is in front.
  void _watchNet() {
    _netTimer?.cancel();
    _netTimer = Timer.periodic(const Duration(seconds: 30), (_) => _checkNet());
    _checkNet();
  }

  /// Online is any IPv4 address besides loopback. A failed look keeps the
  /// last answer.
  Future<void> _checkNet() async {
    try {
      final online = (await NetworkInterface.list(
        type: InternetAddressType.IPv4,
      )).isNotEmpty;
      if (mounted && online != _online) setState(() => _online = online);
    } catch (_) {}
  }

  void _settingsChanged() {
    setState(() {});
    _loadIcons();
  }

  /// Fetches real icons for `app` tiles only; painted icons need no image.
  /// Each is asked once per run, cached or not (an updated app has a new
  /// icon), and kept for the next start when it changed. A failed fetch
  /// leaves the tile as it is and is retried on the next call.
  Future<void> _loadIcons() async {
    for (final tile in _tiles) {
      if (tile.icon != 'app' || !_fetched.add(tile.package)) continue;
      try {
        final png = await Host.appIcon(tile.package);
        if (!mounted) return;
        if (listEquals(png, _icons[tile.package])) continue;
        setState(() => _icons[tile.package] = png);
        if (png != null) {
          widget.store?.writeBytes('icon-${tile.package}.png', png).ignore();
        }
      } catch (_) {
        _fetched.remove(tile.package);
      }
    }
  }

  /// Fades in; pops are instant, so goHome never shows a sub-route leaving.
  void _push(Widget screen) => Navigator.of(context).push(
    PageRouteBuilder<void>(
      pageBuilder: (_, _, _) => screen,
      transitionDuration: const Duration(milliseconds: 150),
      reverseTransitionDuration: Duration.zero,
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );

  void _openSettings() => _push(
    SettingsScreen(widget.settings, widget.sources, pairing: widget.pairing),
  );

  void _open(AppTile tile) {
    switch (tile.package) {
      case 'ilonatv:apps':
        _push(
          AppsScreen(
            offeredApps(_apps ?? const {}, widget.settings.hiddenApps),
          ),
        );
      case 'ilonatv:settings':
        _openSettings();
      default:
        Host.launch(tile.package);
    }
  }

  void _openItem(MediaItem item) => openItemOrSay(
    context,
    item,
    widget.settings,
    widget.sources.tmdb,
    lastVideo: widget.sources.stremio.lastVideo,
  );

  Future<String?> _trailerKey(MediaItem item) =>
      trailerKeyFor(item, widget.sources.tmdb);

  void _openTrailer(String key) =>
      openTrailerKey(key, widget.settings).ignore();

  /// A card of the row [key] got focus, or (null) focus left that row.
  void _rowFocus(String key, BuildContext row, MediaItem? item) {
    if (item == null) {
      // Gone to another row, whose card reports next: the backdrop must not
      // fall back to the rotation in between.
      if (primaryFocus?.context?.findAncestorWidgetOfExactType<ContentRow>() ==
          null) {
        _focused.value = null;
      }
      return;
    }
    _focused.value = item;
    // The row's bottom on the screen's: the band under the highlight.
    Scrollable.ensureVisible(row, alignment: 1, duration: _moveTime);
    _row.value = key;
  }

  void _appRowFocusChanged(bool focused) {
    _onApps.value = focused;
    if (!focused) return;
    _scroll.animateTo(0, duration: _moveTime, curve: Curves.ease);
    _row.value = null;
  }

  /// The corner pill's buttons, left to right.
  List<FocusNode> get _pillButtons => [
    if (_canSearch) _searchFocus,
    _gearFocus,
  ];

  KeyEventResult _toPill() {
    _pillButtons.first.requestFocus();
    return KeyEventResult.handled;
  }

  /// Left and Right move along the pill. The ways out mirror the ways in:
  /// Down to the last app, Left from its first button to the banner's last
  /// (when it has one). Up, and Right at its end, stay put.
  KeyEventResult _pillKey(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    if (e is KeyDownEvent) {
      final buttons = _pillButtons;
      final i = buttons.indexWhere((b) => b.hasPrimaryFocus);
      if (k == LogicalKeyboardKey.arrowDown) {
        _appRowFocus.traversalDescendants.lastOrNull?.requestFocus();
      } else if (k == LogicalKeyboardKey.arrowLeft) {
        if (i > 0) {
          buttons[i - 1].requestFocus();
        } else {
          _bannerFocus.traversalDescendants.lastOrNull?.requestFocus();
        }
      } else if (k == LogicalKeyboardKey.arrowRight &&
          i >= 0 &&
          i < buttons.length - 1) {
        buttons[i + 1].requestFocus();
      }
    }
    return k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown ||
            k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  // Only called with a tile focused, so there is a first and a last.
  KeyEventResult _appRowKey(FocusNode row, KeyEvent e) {
    final tiles = row.traversalDescendants;
    // Up from the last app reaches the corner pill.
    if (e is KeyDownEvent &&
        e.logicalKey == LogicalKeyboardKey.arrowUp &&
        tiles.last.hasPrimaryFocus) {
      return _toPill();
    }
    return _ends(
      e,
      first: tiles.first.hasPrimaryFocus,
      last: tiles.last.hasPrimaryFocus,
    );
  }

  /// Up and Down between the dock and the rows, and from row to row: the row
  /// above or below gets focus on its remembered card, else the one under the
  /// focused card. Flutter's own directional traversal did this by geometry
  /// over every card on the home, and every other press found nothing and
  /// stayed put. Up from the first row lands on the tile nearest the card.
  /// Up from the dock, and the pill and the highlight, keep the traversal.
  KeyEventResult _verticalKey(FocusNode _, KeyEvent e) {
    final k = e.logicalKey;
    if (e is KeyUpEvent ||
        k != LogicalKeyboardKey.arrowUp && k != LogicalKeyboardKey.arrowDown) {
      return KeyEventResult.ignored;
    }
    final x = primaryFocus?.rect.center.dx ?? 0;
    final at = _rowKeys.indexOf(_row.value ?? '');
    final down = k == LogicalKeyboardKey.arrowDown;
    if (at < 0) {
      if (!_appRowFocus.hasFocus || !down) return KeyEventResult.ignored;
      if (_rowKeys.isNotEmpty) _rowFocusNear(_rowKeys.first, x);
      return KeyEventResult.handled;
    }
    if (down) {
      if (at + 1 < _rowKeys.length) _rowFocusNear(_rowKeys[at + 1], x);
    } else if (at > 0) {
      _rowFocusNear(_rowKeys[at - 1], x);
    } else {
      final tiles = _appRowFocus.traversalDescendants.toList()
        ..sort(
          (a, b) => (a.rect.center.dx - x).abs().compareTo(
            (b.rect.center.dx - x).abs(),
          ),
        );
      tiles.firstOrNull?.requestFocus();
    }
    return KeyEventResult.handled;
  }

  void _rowFocusNear(String key, double x) =>
      _rowStates[key]?.currentState?.focusNear(x);

  /// The rows filtered by streaming service, and their kind.
  static const _filtered = {
    'trendingMovies': MediaType.movie,
    'trendingSeries': MediaType.series,
  };

  /// A row's filter, with the titles and the name that go with it: for a
  /// trending row, the saved service and genre while the region offers them
  /// (else All), their row once it is in and the row's own meanwhile, and
  /// the name with the service's and the genre's. The other rows get none.
  (RowFilter?, List<MediaItem>, String) _filter(
    TmdbSource tmdb,
    String key,
    List<MediaItem> items,
  ) {
    final type = _filtered[key];
    if (type == null) return (null, items, rowTitle(key));
    final settings = widget.settings;
    final service = tmdb.providers
        .where((p) => p.id == settings.rowProvider(key))
        .firstOrNull;
    final genre = tmdb.genres
        .where((g) => g.code == settings.rowGenre(key))
        .firstOrNull;
    List<MediaItem>? own;
    if (service != null || genre != null) {
      own = tmdb.providerRowNow(type, service: service?.id, genre: genre?.code);
      // ponytail: asked on every build while nothing is in; the source joins
      // a call under way, so only a failed one is asked again.
      if (own == null) {
        tmdb
            .providerRow(type, service: service?.id, genre: genre?.code)
            .ignore();
      } else if (own.isEmpty) {
        // Nothing for the picks here (a service with no horror films in the
        // country, say): the row keeps its own titles, so it keeps its cards and the
        // rows below stay reachable, and the picks stay on the cards and in
        // the name, so the next pick starts from them.
        own = null;
      }
    }
    void ask(int? serviceId, String? code) {
      settings.save().ignore(); // the home rebuilds on it
      if (serviceId != null || code != null) {
        tmdb.providerRow(type, service: serviceId, genre: code).ignore();
      }
    }

    return (
      RowFilter(
        options: tmdb.providers,
        selected: service?.id,
        onChanged: (id) {
          settings.setRowProvider(key, id);
          ask(id, genre?.code);
        },
        genres: tmdb.genres,
        genre: genre?.code,
        onGenre: (code) {
          settings.setRowGenre(key, code);
          ask(service?.id, code);
        },
      ),
      own ?? items,
      [t(key), service?.name, genre?.name].nonNulls.join(' · '),
    );
  }

  /// With the rows up, Back brings them down and focus to the first app.
  void _back() {
    if (!_scroll.hasClients || _scroll.offset == 0) return;
    _scroll.animateTo(0, duration: _moveTime, curve: Curves.ease);
    _appRowFocus.traversalDescendants.firstOrNull?.requestFocus();
  }

  /// The weather, and under it a hint while TMDB has no key or refuses it.
  Widget _weather(TmdbSource tmdb) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      WeatherLine(
        source: widget.sources.weather,
        city: widget.settings.weatherCity,
      ),
      if (tmdb.error == TmdbError.noKey || tmdb.error == TmdbError.badKey)
        Text(
          t(tmdb.error == TmdbError.noKey ? 'noTmdbKey' : 'tmdbKeyRejected'),
          style: const TextStyle(fontSize: 12, color: Color(0xB3FFFFFF)),
        ),
    ],
  );

  /// The focused card, else the item whose backdrop is up. Only the latter has
  /// a button, reached with Up from the app row: OK on a card opens the card.
  Widget _highlight() => Focus(
    focusNode: _bannerFocus,
    // Left on Watch stays put; Right on the last button goes to the corner
    // pill.
    onKeyEvent: (node, e) {
      final buttons = node.traversalDescendants;
      if (e is KeyDownEvent &&
          e.logicalKey == LogicalKeyboardKey.arrowRight &&
          (buttons.lastOrNull?.hasPrimaryFocus ?? false)) {
        return _toPill();
      }
      return _ends(
        e,
        first: buttons.firstOrNull?.hasPrimaryFocus ?? true,
        last: buttons.lastOrNull?.hasPrimaryFocus ?? true,
      );
    },
    child: ListenableBuilder(
      listenable: Listenable.merge([_focused, _shown]),
      builder: (context, _) {
        final focused = _focused.value;
        final item = focused ?? _shown.value;
        final tmdb = widget.sources.tmdb;
        // A known console on an input: its wordmark for the title, its port
        // ("HDMI 1") for the chip.
        final brand = item?.type == MediaType.input
            ? InputBrand.of(item!.genre)
            : null;
        // The future only rebuilds this when TMDB's answer is in; what is
        // shown is read at once, so an item seen before never blinks.
        return FutureBuilder(
          future: item == null ? null : tmdb.about(item),
          builder: (context, _) {
            final about = item == null ? null : tmdb.aboutNow(item);
            return Highlight(
              item: brand != null
                  ? MediaItem(
                      type: item!.type,
                      id: item.id,
                      title: item.genre,
                      genre: item.title,
                    )
                  : about?.item ?? item,
              logoUrl: about?.logo,
              logoAsset: brand?.asset,
              logoPending: item != null && about == null,
              watchOn: item == null || about == null
                  ? null
                  : watchOn(
                      item,
                      about.providers,
                      widget.settings,
                      _apps?.keys,
                    ),
              onOpen: focused != null || item == null
                  ? null
                  : () => _openItem(item),
              // Films and series only; nothing opens when there is no trailer.
              onTrailer:
                  focused != null ||
                      item == null ||
                      item.type != MediaType.movie &&
                          item.type != MediaType.series
                  ? null
                  : () async {
                      final key = await _trailerKey(item)
                          .catchError((_) => null);
                      if (key != null) _openTrailer(key);
                    },
            );
          },
        );
      },
    ),
  );

  /// The app row alone on the first screen, 9 % above its bottom, and the
  /// content rows below the fold. One row is on screen at a time: each content
  /// row gets at least the band under the highlight, so at the bottom it has
  /// pushed the one before under the clip.
  Widget _rows(Size size, Map<String, InstalledApp> apps, TmdbSource tmdb) {
    final rows = widget.settings.shownRows({
      'inputs': _inputs,
      ...widget.sources.rowItems(),
    });
    // The rows changed (a refresh): the switches follow, after this frame.
    final keys = [for (final r in rows) r.$1];
    if (!listEquals(keys, _rowKeys)) {
      _rowKeys = keys;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _rowChanged();
      });
    }
    final at = keys.indexOf(_row.value ?? '');
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _verticalKey,
      child: SingleChildScrollView(
        controller: _scroll,
        // The lifted card's shadow may run past the viewport's bottom edge.
        clipBehavior: Clip.none,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              // The viewport ends at the safe band; the dock stays where it was.
              height: size.height - _bottomSafe(size),
              padding: EdgeInsets.only(
                bottom: 0.09 * size.height - _bottomSafe(size),
              ),
              alignment: Alignment.bottomLeft,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // There is more below.
                  ValueListenableBuilder(
                    valueListenable: _onApps,
                    builder: (_, onApps, hint) => AnimatedOpacity(
                      key: const ValueKey('more'),
                      opacity: onApps && rows.isNotEmpty ? 1 : 0,
                      duration: _moveTime,
                      child: hint,
                    ),
                    child: const Icon(
                      Icons.keyboard_arrow_up,
                      size: 28,
                      color: Color(0x99FFFFFF),
                    ),
                  ),
                  Focus(
                    focusNode: _appRowFocus,
                    onFocusChange: _appRowFocusChanged,
                    onKeyEvent: _appRowKey,
                    child: AppRow(
                      tiles: _tiles,
                      apps: apps,
                      icons: _icons,
                      onOpen: _open,
                      onLongPress: _openSettings,
                    ),
                  ),
                ],
              ),
            ),
            // No semantics for the cards: the D-pad never reads them, and the
            // tree of a hundred cards cost the TV 20 ms on every move.
            for (final (i, (key, items)) in rows.indexed)
              Container(
                key: ValueKey(key),
                constraints: BoxConstraints(minHeight: _rowHeight(size)),
                padding: const EdgeInsets.only(top: _rowPadTop),
                alignment: Alignment.bottomLeft,
                // Only the focused row is drawn: the one focus left goes at
                // once, so nothing of it (its lifted card) shows passing
                // through the band while the new row slides into it, and the
                // GPU draws one row's cards a frame, not two.
                child: ExcludeSemantics(
                  child: ValueListenableBuilder(
                    valueListenable: _row,
                    builder: (_, row, cards) =>
                        Opacity(opacity: row == key ? 1 : 0, child: cards),
                    child: ValueListenableBuilder(
                      valueListenable: _rowImages.putIfAbsent(
                        key,
                        () => ValueNotifier(_showsImages(i, at)),
                      ),
                      builder: (row, images, _) {
                        final (filter, shown, title) = _filter(
                          tmdb,
                          key,
                          items,
                        );
                        // A sport's games row (`games:soccer`) is the games'.
                        final wide = _wideRows.contains(key.split(':').first);
                        return ContentRow(
                          key: _rowStates.putIfAbsent(key, GlobalKey.new),
                          title: title,
                          items: shown,
                          // Video thumbs, games and inputs; the others are
                          // posters.
                          wide: wide,
                          images: images,
                          onFocus: (item) => _rowFocus(key, row, item),
                          onOpen: _openItem,
                          trailerKey: wide ? null : _trailerKey,
                          onTrailer: _openTrailer,
                          filter: filter,
                        );
                      },
                    ),
                  ),
                ),
              ),
            SizedBox(height: 0.09 * size.height),
          ],
        ),
      ),
    );
  }

  /// The corner pill: the network's state, the magnifier (with a TMDB key)
  /// and the gear. It lights up while one of its buttons has focus.
  Widget _pill() => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onFocusChange: (f) => _onPill.value = f,
    onKeyEvent: _pillKey,
    child: Glass(
      child: ValueListenableBuilder(
        valueListenable: _onPill,
        builder: (_, onPill, buttons) => DecoratedBox(
          decoration: BoxDecoration(
            color: onPill ? const Color(0x40FFFFFF) : const Color(0x00FFFFFF),
            borderRadius: const BorderRadius.all(Radius.circular(22)),
          ),
          child: buttons,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 2,
            children: [
              Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  _online ? Icons.wifi : Icons.wifi_off,
                  size: 20,
                  semanticLabel: t(_online ? 'sysNetwork' : 'networkError'),
                  color: const Color(0xCCFFFFFF),
                ),
              ),
              if (_canSearch)
                TextButton(
                  focusNode: _searchFocus,
                  onPressed: () =>
                      _push(SearchScreen(widget.settings, widget.sources)),
                  style: _pillButton,
                  child: Icon(
                    Icons.search,
                    size: 20,
                    semanticLabel: t('search'),
                  ),
                ),
              TextButton(
                focusNode: _gearFocus,
                onPressed: _openSettings,
                style: _pillButton,
                child: Icon(
                  Icons.settings_outlined,
                  size: 20,
                  semanticLabel: t('settings'),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final left = 0.04 * size.width;
    final tmdb = widget.sources.tmdb;
    final stremio = widget.sources.stremio;
    final youtube = widget.sources.youtube;
    final sports = widget.sources.sports;
    // The launcher never exits: Back on the home only brings the rows down.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, _) => _back(),
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.contextMenu): _openSettings,
        },
        child: Scaffold(
          body: ListenableBuilder(
            listenable: Listenable.merge([tmdb, stremio, youtube, sports]),
            builder: (context, _) => Stack(
              children: [
                Positioned.fill(
                  child: ValueListenableBuilder(
                    valueListenable: _row,
                    builder: (_, row, _) => Backdrop(
                      focused: _focused,
                      // The country's popular titles (JustWatch), else the
                      // trending films.
                      rotation:
                          (tmdb.popular.isNotEmpty ? tmdb.popular : tmdb.movies)
                              .where((m) => m.backdropUrl != null)
                              .take(10)
                              .toList(),
                      dimmed: row != null,
                      onShown: (item) => _shown.value = item,
                    ),
                  ),
                ),
                // Their own layers: what does not change between frames is
                // kept as a texture (the raster cache) instead of being drawn
                // again on every frame of a move.
                Positioned(
                  left: left,
                  top: 0.03 * size.height,
                  child: const RepaintBoundary(child: Clock()),
                ),
                Positioned(
                  left: left,
                  top: 0.03 * size.height + 64,
                  child: RepaintBoundary(child: _weather(tmdb)),
                ),
                // Anchored under the clock and weather, not over the rows:
                // the highlight's parts keep fixed heights, so from here down
                // title, chips, synopsis and buttons never move or climb.
                Positioned(
                  left: left,
                  top: 0.215 * size.height,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: 0.55 * size.width),
                    child: RepaintBoundary(child: _highlight()),
                  ),
                ),
                if (_apps case final apps?)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    // tvOS keeps 60 px clear at the bottom: the focused row
                    // stops there instead of touching the screen's edge.
                    bottom: _bottomSafe(size),
                    // Rows slide under an edge just below the highlight
                    // instead of fading: nothing above it is drawn. The edge
                    // sits at the focused row's title, so the row above it,
                    // whose lifted card's shadow reaches 48 px past its
                    // bounds, cannot peek through the padding between them.
                    child: ClipRect(
                      clipper: _BelowHighlight(
                        size.height -
                            _bottomSafe(size) -
                            _rowHeight(size) +
                            _rowPadTop -
                            4,
                      ),
                      child: _rows(size, apps, tmdb),
                    ),
                  ),
                Positioned(
                  right: left,
                  top: 0.03 * size.height,
                  // The pill's shadow is a blur: drawn once, not every frame.
                  child: RepaintBoundary(child: _pill()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Bare on the pill's glass at rest; black on white with focus.
const _pillButton = ButtonStyle(
  foregroundColor: WidgetStateColor.fromMap({
    WidgetState.focused: Colors.black,
    WidgetState.any: Color(0xCCFFFFFF),
  }),
  backgroundColor: WidgetStateColor.fromMap({
    WidgetState.focused: Colors.white,
    WidgetState.any: Colors.transparent,
  }),
  side: WidgetStatePropertyAll(BorderSide.none),
  shape: WidgetStatePropertyAll(CircleBorder()),
  minimumSize: WidgetStatePropertyAll(Size.zero),
  padding: WidgetStatePropertyAll(EdgeInsets.all(8)),
);

/// Everything under [top], the bottom edge of the highlight.
/// tvOS's safe area at the bottom: 60 px of 1080.
double _bottomSafe(Size size) => 0.055 * size.height;

/// Room above a row's title, where the row above it would otherwise show the
/// shadow of its lifted card.
const _rowPadTop = 40.0;

/// A row's slot: its band of the screen plus the room above its title.
double _rowHeight(Size size) => 0.38 * size.height + 8 + (_rowPadTop - 24);

class _BelowHighlight extends CustomClipper<Rect> {
  final double top;
  const _BelowHighlight(this.top);

  @override
  Rect getClip(Size size) => Rect.fromLTRB(0, top, size.width, size.height);

  @override
  bool shouldReclip(_BelowHighlight old) => old.top != top;
}
