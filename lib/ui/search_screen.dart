import 'package:flutter/material.dart';

import '../data/media.dart';
import '../data/tmdb.dart' show inTurns;
import '../i18n.dart';
import '../providers.dart';
import '../settings.dart';
import '../sources.dart';
import 'content_row.dart';
import 'glass.dart';
import 'settings_panes.dart' show TvField, fieldDecoration;

const _label = TextStyle(fontSize: 14, height: 1.4, color: Color(0xB3FFFFFF));

/// The search field's pill, as the Glass around it.
const _pill = BorderRadius.all(Radius.circular(22));

/// A last search: a small glass pill.
const _recentStyle = ButtonStyle(
  padding: WidgetStatePropertyAll(
    EdgeInsets.symmetric(horizontal: 20, vertical: 10),
  ),
  textStyle: WidgetStatePropertyAll(TextStyle(fontSize: 18)),
);

/// A field as wide as the rows, and once it is confirmed, TMDB's films and
/// series for it in two rows that open as the home's do, trailer included,
/// and YouTube's videos as the first account finds them, if there is one.
/// With the field empty, three rows to discover titles by: the best rated,
/// hidden gems and a genre of the day. Back pops.
class SearchScreen extends StatefulWidget {
  final Settings settings;
  final Sources sources;

  /// The day the genre of the day is picked for; tests set it.
  final DateTime Function() today;
  const SearchScreen(
    this.settings,
    this.sources, {
    super.key,
    this.today = DateTime.now,
  });

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _query = TextEditingController();
  final _field = FocusNode();

  /// Around the rows, to put focus on the first card.
  final _results = FocusNode(canRequestFocus: false, skipTraversal: true);

  // Both null until an answer, and after a failed one.
  List<MediaItem>? _movies;
  List<MediaItem>? _series;
  var _error = false;

  /// Empty without a YouTube account, or when its search failed.
  var _videos = const <MediaItem>[];

  /// The discovery rows (key, title, titles) in order, as they come; a row
  /// that fails or is empty is left out.
  final _discovery = <(String, String, List<MediaItem>)>[];

  /// The rows swap between discovery and results as the field empties.
  var _empty = true;

  @override
  void initState() {
    super.initState();
    _query.addListener(() {
      final empty = _query.text.trim().isEmpty;
      if (empty != _empty) setState(() => _empty = empty);
    });
    if (widget.settings.tmdbKey.isNotEmpty) _discover();
  }

  Future<void> _discover() async {
    // One client for the three rows, so each genre list is asked once.
    final c = widget.sources.tmdb.client;
    Future<List<MediaItem>> both(
      Future<List<MediaItem>> Function(MediaType) list,
    ) async {
      final (movies, series) = await (
        list(MediaType.movie),
        list(MediaType.series),
      ).wait;
      return inTurns([movies, series]);
    }

    // Films only: the genre ids are the films'.
    Future<(String, String, List<MediaItem>)?> genre() async {
      final g = await c.genreOfTheDay(widget.today());
      if (g == null) return null;
      final (id, name) = g;
      final items = await c.discoverGenre(MediaType.movie, id);
      return ('genre', '$name ${t('inSpotlight')}', items);
    }

    try {
      // The genre lists first; the rows below reuse them.
      await (c.genres(MediaType.movie), c.genres(MediaType.series)).wait;
    } catch (_) {
      return;
    }
    // Each row fails alone.
    final rows = await [
      both(c.topRated).then<(String, String, List<MediaItem>)?>(
        (l) => ('topRated', t('topRated'), l),
      ),
      both(c.hiddenGems).then<(String, String, List<MediaItem>)?>(
        (l) => ('hiddenGems', t('hiddenGems'), l),
      ),
      genre(),
    ].map((row) => row.catchError((_) => null)).wait;
    if (!mounted) return;
    // A title shows once, in the first row that has it: TMDB's top rated and
    // hidden gems overlap a lot.
    final seen = <String>{};
    setState(
      () => _discovery.addAll([
        for (final row in rows)
          if (row != null)
            if ([
                  for (final i in row.$3)
                    if (seen.add(i.key)) i,
                ]
                case final items when items.isNotEmpty)
              (row.$1, row.$2, items),
      ]),
    );
  }

  /// What the first enabled, signed-in YouTube account finds for [query];
  /// none without one or when the call fails.
  Future<List<MediaItem>> _youtube(String query) async {
    final source = widget.sources.youtube;
    final account = widget.settings.youtubeAccounts
        .where((a) => a.enabled && !source.isRevoked(a))
        .firstOrNull;
    if (account == null) return const [];
    final client = source.client;
    try {
      return await client.search(
        query,
        accessToken: await client.accessToken(account.refreshToken),
        pageId: account.pageId,
      );
    } catch (_) {
      return const [];
    }
  }

  void _searchAgain(String query) {
    _query.text = query;
    _search();
  }

  void _clearRecent() {
    setState(() => widget.settings.recentSearches = []);
    widget.settings.saveRecentSearches().ignore();
    _field.requestFocus();
  }

  @override
  void dispose() {
    _query.dispose();
    _field.dispose();
    _results.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    final client = widget.sources.tmdb.client;
    final videos = _youtube(query);
    List<MediaItem>? movies, series;
    try {
      (movies, series) = await (
        client.search(MediaType.movie, query),
        client.search(MediaType.series, query),
      ).wait;
    } catch (_) {}
    final found = await videos;
    // Dropped when the field changed while the calls were out.
    if (!mounted || query != _query.text.trim()) return;
    if (movies != null || found.isNotEmpty) {
      widget.settings.addRecentSearch(query);
      widget.settings.saveRecentSearches().ignore();
    }
    setState(() {
      _movies = movies ?? const [];
      _series = series ?? const [];
      _videos = found;
      _error = movies == null && found.isEmpty;
    });
    // The submit took focus off the field: onto the first card, else back.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      (_results.traversalDescendants.firstOrNull ?? _field).requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final tmdb = widget.sources.tmdb;
    final rows = _empty
        ? _discovery
        : [
            ('movies', t('movies'), _movies ?? const <MediaItem>[]),
            ('series', t('series'), _series ?? const <MediaItem>[]),
            ('youtube', t('youtube'), _videos),
          ];
    final searched = !_empty && _movies != null;
    return Scaffold(
      body: SingleChildScrollView(
        padding: EdgeInsets.only(top: 0.03 * size.height, bottom: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 24,
          children: [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 0.04 * size.width),
              child: Glass(
                child: TvField(
                  (readOnly) => TextField(
                    controller: _query,
                    focusNode: _field,
                    autofocus: true,
                    readOnly: readOnly,
                    enableInteractiveSelection: false,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    // The glass is the fill; focus draws the ring on its edge.
                    decoration: fieldDecoration(t('search')).copyWith(
                      filled: false,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 16,
                      ),
                      enabledBorder: const OutlineInputBorder(
                        borderSide: BorderSide.none,
                        borderRadius: _pill,
                      ),
                      focusedBorder: const OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white, width: 2),
                        borderRadius: _pill,
                      ),
                    ),
                  ),
                  width: 0.92 * size.width,
                ),
              ),
            ),
            // The last searches, while the field is empty: OK searches again.
            if (_empty && widget.settings.recentSearches.isNotEmpty)
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 0.04 * size.width),
                child: Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final q in widget.settings.recentSearches)
                      TextButton(
                        onPressed: () => _searchAgain(q),
                        style: _recentStyle,
                        child: Text(q),
                      ),
                    TextButton.icon(
                      onPressed: _clearRecent,
                      style: _recentStyle,
                      icon: const Icon(Icons.close, size: 18),
                      label: Text(t('clearRecent')),
                    ),
                  ],
                ),
              ),
            if (_error && !_empty)
              Padding(
                padding: EdgeInsets.only(left: 0.04 * size.width),
                child: Text(t('networkError'), style: _label),
              )
            else if (searched && rows.every((r) => r.$3.isEmpty))
              Padding(
                padding: EdgeInsets.only(left: 0.04 * size.width),
                child: Text(t('noResults'), style: _label),
              ),
            Focus(
              focusNode: _results,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 24,
                children: [
                  for (final (key, title, items) in rows)
                    if (items.isNotEmpty)
                      Builder(
                        builder: (row) => ContentRow(
                          key: ValueKey(key),
                          title: title,
                          items: items,
                          wide: key == 'youtube',
                          // The rows' own traversal scrolls only sideways.
                          onFocus: (item) {
                            if (item != null) {
                              Scrollable.ensureVisible(
                                row,
                                alignment: 0.5,
                                duration: const Duration(milliseconds: 200),
                              );
                            }
                          },
                          onOpen: (item) => openItemOrSay(
                            context,
                            item,
                            widget.settings,
                            tmdb,
                            lastVideo: widget.sources.stremio.lastVideo,
                          ),
                          trailerKey: key == 'youtube'
                              ? null
                              : (item) => trailerKeyFor(item, tmdb),
                          onTrailer: (key) =>
                              openTrailerKey(key, widget.settings).ignore(),
                        ),
                      ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
