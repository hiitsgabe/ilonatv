import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../host.dart';
import '../i18n.dart';
import '../settings.dart';
import 'tile.dart';
import 'tile_icons.dart';

const _dialogColor = Color(0xFF1C1C20);
const _dialogTitle = TextStyle(fontSize: 18, fontWeight: FontWeight.w600);
const _previewWidth = 112.0;
// The home row fits five tiles (AppRow).
const _maxTiles = 5;

/// A newly chosen app's icon: its own, or for a pseudo package the painted
/// icon its suffix names (`apps`, `settings`), never a grey box.
String newTileIcon(String package) =>
    package.startsWith('ilonatv:') ? package.replaceFirst('ilonatv:', '') : 'app';

/// The custom image entry of the icon picker.
const _custom = 'ilonatv:image';

/// The backgrounds of a centred custom image, after glass.
const _swatches = [
  0xFF0E0E10,
  0xFFF2F0EB,
  0xFF1F2A44,
  0xFF3A6EA5,
  0xFF2E4A3F,
  0xFF7A1F2B,
  0xFFB8892E,
  0xFF5B3A8C,
];

/// Deletes the copy of [old]'s custom image unless [now] still shows it.
void _dropImage(AppTile old, [AppTile? now]) {
  final path = old.image;
  if (path == null || path == now?.image) return;
  try {
    File(path).deleteSync();
  } on FileSystemException {
    // Already gone.
  }
}

/// [title] above [body]; an entry pops its value, Back pops null.
Future<T?> _dialog<T>(BuildContext context, String title, Widget body) =>
    showDialog<T>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: _dialogColor,
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 16,
            children: [
              Text(title, style: _dialogTitle),
              body,
            ],
          ),
        ),
      ),
    );

/// The package of an app picked from [apps], or the value of one of [first]
/// (value, label), listed before them; null for Back. The focus starts on
/// [focus] when it is listed, else on the first.
Future<String?> pickAppDialog(
  BuildContext context,
  Map<String, InstalledApp> apps, {
  List<(String, String)> first = const [],
  String? focus,
}) {
  final size = MediaQuery.sizeOf(context);
  final choices = [
    ...first,
    for (final app in apps.values) (app.package, app.label),
  ];
  final focused = choices.indexWhere((c) => c.$1 == focus);
  return _dialog(
    context,
    t('chooseApp'),
    SizedBox(
      width: 0.4 * size.width,
      height: 0.7 * size.height,
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 6,
          children: [
            for (final (i, (package, label)) in choices.indexed)
              Builder(
                builder: (button) => TextButton(
                  autofocus: i == (focused < 0 ? 0 : focused),
                  // The first focus may be far down the list.
                  onFocusChange: (f) {
                    if (f) Scrollable.ensureVisible(button, alignment: 0.5);
                  },
                  style: const ButtonStyle(alignment: Alignment.centerLeft),
                  onPressed: () => Navigator.pop(context, package),
                  child: Text(label),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

/// Edits [Settings.tiles], hidden tiles included, so a tile whose app is gone
/// can still be fixed or removed. Every change saves, which redraws the home.
class TileEditor extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  const TileEditor(this.settings, this.apps, {super.key});

  @override
  State<TileEditor> createState() => _TileEditorState();
}

class _TileEditorState extends State<TileEditor> {
  // A null value is an app with no icon, kept so it is not asked again.
  final _icons = <String, Uint8List?>{};
  // By (row, action), so focus can follow a moved row or land beside a
  // removed one. Row -1 is the Add button.
  final _nodes = <(int, String), FocusNode>{};

  List<AppTile> get _tiles => widget.settings.tiles;

  @override
  void initState() {
    super.initState();
    for (final tile in _tiles) {
      if (tile.icon == 'app') _loadIcon(tile.package);
    }
  }

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node((int, String) key) => _nodes.putIfAbsent(key, FocusNode.new);

  /// A failed fetch leaves the preview grey and is retried on the next ask.
  Future<void> _loadIcon(String package) async {
    if (_icons.containsKey(package)) return;
    try {
      final png = await Host.appIcon(package);
      if (mounted) setState(() => _icons[package] = png);
    } catch (_) {}
  }

  Future<void> _save() async {
    await widget.settings.save();
    if (mounted) setState(() {});
  }

  /// Saves, then puts focus on [target] once the rows are rebuilt.
  Future<void> _saveAndFocus((int, String) target) async {
    await _save();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _node(target)..requestFocus();
      final context = node.context;
      if (context == null) return;
      // Arrow keys return to where they came from; the rows have shifted
      // since, so drop that memory.
      FocusTraversalGroup.of(context).invalidateScopeData(node.nearestScope!);
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  Future<String?> _pickApp() => pickAppDialog(
    context,
    offeredApps(widget.apps, widget.settings.hiddenApps),
    first: [('ilonatv:apps', t('apps')), ('ilonatv:settings', t('settings'))],
  );

  Future<void> _chooseApp(int i) async {
    final package = await _pickApp();
    if (package == null) return;
    _dropImage(_tiles[i]);
    _tiles[i] = AppTile(package, newTileIcon(package));
    if (_tiles[i].icon == 'app') _loadIcon(package);
    await _save();
  }

  Future<void> _chooseIcon(int i) async {
    final old = _tiles[i];
    await _loadIcon(old.package);
    if (!mounted) return;
    final look = await _pickLook(old);
    if (look == null) return;
    _dropImage(old, look);
    _tiles[i] = look;
    await _save();
  }

  /// The row keeps focus on the same button; past either end nothing moves.
  void _move(int i, int to, String action) {
    widget.settings.moveTile(i, to);
    _saveAndFocus((to >= 0 && to < _tiles.length ? to : i, action));
  }

  /// Focus lands on the row that took this one's place, or the one above.
  void _remove(int i) {
    // One tile at least: an empty row would leave the home nothing to focus.
    if (_tiles.length == 1) return;
    _dropImage(_tiles[i]);
    widget.settings.removeTileAt(i);
    final row = min(i, _tiles.length - 1);
    _saveAndFocus(row < 0 ? (-1, 'addTile') : (row, 'removeTile'));
  }

  /// Picks the app, then its icon: Back on the app adds nothing, Back on the
  /// icon keeps the default one.
  Future<void> _add() async {
    final package = await _pickApp();
    if (package == null) return;
    await _loadIcon(package);
    if (!mounted) return;
    final tile = AppTile(package, newTileIcon(package));
    widget.settings.addTile(await _pickLook(tile) ?? tile);
    // The last free slot takes Add away, so focus moves to the new row.
    final n = _tiles.length;
    await _saveAndFocus(
      n < _maxTiles ? (-1, 'addTile') : (n - 1, 'chooseIcon'),
    );
  }

  // As wide as a home tile, five to a row.
  double get _tileWidth => 0.165 * 0.92 * MediaQuery.sizeOf(context).width;

  /// [tile] with the look the user picks: a painted icon, the app's own, or a
  /// custom image and its style; null for Back at any step.
  Future<AppTile?> _pickLook(AppTile tile) async {
    final names = [
      for (final icon in TileIcon.values) icon.name,
      // A pseudo package has no icon of its own: it would stay grey.
      if (!tile.package.startsWith('ilonatv:')) 'app',
    ];
    final icon = await _pickTile(
      t('chooseIcon'),
      [for (final name in names) (AppTile(tile.package, name), name, null)],
      focus: names.contains(tile.icon) ? tile.icon : names.first,
      after: TextButton(
        onPressed: () => Navigator.pop(context, _custom),
        child: Text(t('customImage')),
      ),
    );
    if (icon != _custom || !mounted) {
      return icon == null ? null : AppTile(tile.package, icon);
    }
    final path = await _dialog<String>(
      context,
      t('chooseImage'),
      _ImagePicker(5 * _tileWidth + 4 * 16),
    );
    if (path == null) return null;
    AppTile look(bool centered, [int? background]) => AppTile(
      tile.package,
      tile.icon,
      image: path,
      centered: centered,
      background: background,
    );
    var picked = !mounted
        ? null
        : await _pickTile(t('imageStyle'), [
            (look(false), look(false), t('imageFill')),
            (look(true), look(true), t('imageCentered')),
          ]);
    if (picked != null && picked.centered && mounted) {
      picked = await _pickTile(t('tileBackground'), [
        for (final c in [null, ..._swatches])
          (look(true, c), look(true, c), null),
      ]);
    }
    if (picked == null) _dropImage(look(false));
    return picked;
  }

  /// Previews of [choices] (tile, value, label) as on the home, [after] below
  /// them; OK pops the value, the focus starts on [focus] or the first.
  Future<T?> _pickTile<T>(
    String title,
    List<(AppTile, T, String?)> choices, {
    T? focus,
    Widget? after,
  }) {
    final w = _tileWidth;
    return _dialog<T>(
      context,
      title,
      SizedBox(
        width: 5 * w + 4 * 16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                for (final (i, (tile, value, label)) in choices.indexed)
                  SizedBox(
                    width: w,
                    child: Column(
                      spacing: 8,
                      children: [
                        Tile(
                          tile: tile,
                          realIcon: _icons[tile.package],
                          autofocus: focus == null ? i == 0 : value == focus,
                          onOpen: () => Navigator.pop(context, value),
                          onLongPress: () {},
                        ),
                        if (label != null) Text(label),
                      ],
                    ),
                  ),
              ],
            ),
            ?after,
          ],
        ),
      ),
    );
  }

  Widget _action(int i, String key, VoidCallback onPressed) => TextButton(
    key: ValueKey(key),
    focusNode: _node((i, key)),
    onPressed: onPressed,
    style: const ButtonStyle(visualDensity: VisualDensity.compact),
    child: Text(t(key), style: const TextStyle(fontSize: 13)),
  );

  Widget _row(int i) {
    final tile = _tiles[i];
    final app = widget.apps[tile.package];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        spacing: 16,
        children: [
          SizedBox(
            width: _previewWidth,
            child: ExcludeFocus(
              child: Tile(
                tile: tile,
                realIcon: _icons[tile.package],
                onOpen: () {},
                onLongPress: () {},
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 8,
              children: [
                if (app != null)
                  Text(app.label)
                // A pseudo package's suffix is its i18n key.
                else if (tile.package.startsWith('ilonatv:'))
                  Text(t(tile.package.replaceFirst('ilonatv:', '')))
                else
                  Text(
                    '${tile.package} · ${t('notInstalled')}',
                    style: const TextStyle(color: Color(0x80FFFFFF)),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _action(i, 'chooseApp', () => _chooseApp(i)),
                    _action(i, 'chooseIcon', () => _chooseIcon(i)),
                    _action(i, 'moveLeft', () => _move(i, i - 1, 'moveLeft')),
                    _action(i, 'moveRight', () => _move(i, i + 1, 'moveRight')),
                    _action(i, 'removeTile', () => _remove(i)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < _tiles.length; i++) _row(i),
        if (_tiles.length < _maxTiles)
          Padding(
            // In the action column: under the previews it would be the
            // nearest thing to the left of every row's first action.
            padding: const EdgeInsets.only(left: _previewWidth + 16),
            child: TextButton(
              focusNode: _node((-1, 'addTile')),
              onPressed: _add,
              child: Text(t('addTile')),
            ),
          ),
      ],
    ),
  );
}

/// The pictures on the device, newest first, as a grid of [width] whose
/// thumbnails load as they scroll in. OK on one copies it into Ilona TV's files
/// and pops the copy's path. Without read access or without pictures, it says
/// how to put some on the TV, with a retry.
class _ImagePicker extends StatefulWidget {
  final double width;
  const _ImagePicker(this.width);

  @override
  State<_ImagePicker> createState() => _ImagePickerState();
}

class _ImagePickerState extends State<_ImagePicker> {
  var _loading = true;
  List<String>? _uris;
  // A null value is a thumbnail asked for and not (yet) there.
  final _thumbs = <String, Uint8List?>{};
  var _copying = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    List<String>? uris;
    try {
      uris = await Host.images();
    } catch (_) {
      uris = const [];
    }
    if (mounted) {
      setState(() {
        _uris = uris;
        _loading = false;
      });
    }
  }

  void _thumb(String uri) {
    if (_thumbs.containsKey(uri)) return;
    _thumbs[uri] = null;
    Host.imageThumb(uri).then((png) {
      if (mounted) setState(() => _thumbs[uri] = png);
    }, onError: (_) {});
  }

  // One copy at a time: a second OK would pop the editor's page too.
  Future<void> _pick(String uri) async {
    if (_copying) return;
    _copying = true;
    String? path;
    try {
      path = await Host.copyImage(uri);
    } catch (_) {}
    _copying = false;
    if (path != null && mounted) Navigator.pop(context, path);
  }

  @override
  Widget build(BuildContext context) {
    final uris = _uris;
    if (_loading) {
      return SizedBox(
        width: widget.width,
        height: 120,
        child: const Center(child: CircularProgressIndicator()),
      );
    }
    if (uris == null || uris.isEmpty) {
      return SizedBox(
        width: widget.width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Text(t(uris == null ? 'imagesDenied' : 'imagesNone')),
            Text(
              t('imagesHowTo'),
              style: const TextStyle(color: Color(0x99FFFFFF)),
            ),
            TextButton(
              autofocus: true,
              onPressed: _load,
              child: Text(t('checkAgain')),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      width: widget.width,
      height: 0.6 * MediaQuery.sizeOf(context).height,
      child: GridView.builder(
        // Room for the focused tile's lift and scale.
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 5,
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 5 / 3,
        ),
        itemCount: uris.length,
        itemBuilder: (_, i) {
          final uri = uris[i];
          _thumb(uri);
          return Tile(
            tile: const AppTile('', 'app'),
            realIcon: _thumbs[uri],
            autofocus: i == 0,
            onOpen: () => _pick(uri),
            onLongPress: () {},
          );
        },
      ),
    );
  }
}
