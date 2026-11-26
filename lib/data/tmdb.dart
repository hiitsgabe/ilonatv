import 'dart:async';

import 'package:flutter/foundation.dart';

import '../net.dart';
import '../settings.dart';
import '../store.dart';
import 'justwatch.dart';
import 'media.dart';

export 'justwatch.dart' show Genre, WatchProvider;

const _imageBase = 'https://image.tmdb.org/t/p';

/// How old the cached rows may be, and how often the open app asks again.
const _every = Duration(hours: 6);

/// How long an IMDb id, or the lack of one, is remembered.
const _imdbEvery = Duration(days: 7);

const _cache = 'tmdb';

/// Bumped when the cached items gain a field the rows need (2: overview,
/// 4: the streaming services, 6: JustWatch's, with their short names, and
/// the country's popular titles, 7: those as TMDB has them, 8: the genres,
/// 9: where the rows come from).
const _shape = 9;
const _imdbCache = 'imdb_ids';
const _providersCache = 'watch_providers';

/// The newest answers kept in [_providersCache], which is read and written
/// whole for each title.
@visibleForTesting
const kProvidersKept = 500;

/// The rows filtered by streaming services or a genre, by
/// `<region>|<language>|<kind>|<services>|<genre>`; a new shape starts a new
/// entry.
const _rowsCache = 'service_rows$_shape';

/// What is wrong when [TmdbSource.error] is not null. [TmdbClient] throws
/// [badKey] and [network] itself.
enum TmdbError {
  /// Settings holds no key, so TMDB is not asked.
  noKey,

  /// TMDB answered 401.
  badKey,

  /// Anything else that went wrong with the call.
  network,
}

/// TMDB's name for the kind of title; [MediaType.video] is not TMDB's.
String _kind(MediaType type) => type == MediaType.series ? 'tv' : 'movie';

/// One entry of a TMDB list, or null for one without an id. [type] is the kind
/// of list it came from, unless the entry says its own.
MediaItem? _item(Map json, MediaType type, Map<int, String> genres) {
  final id = json['id'];
  if (id == null) return null;
  final date =
      (json['release_date'] ?? json['first_air_date']) as String? ?? '';
  final rating = ((json['vote_average'] as num? ?? 0) * 10).round() / 10;
  final poster = json['poster_path'] as String?;
  final backdrop = json['backdrop_path'] as String?;
  final genreIds = json['genre_ids'] as List? ?? const [];
  return MediaItem(
    type: switch (json['media_type']) {
      'movie' => MediaType.movie,
      'tv' => MediaType.series,
      _ => type,
    },
    id: '$id',
    title: (json['title'] ?? json['name'] ?? '') as String,
    year: date.length < 4 ? null : int.tryParse(date.substring(0, 4)),
    // The first of the genres that the list has a name for.
    genre: genreIds.map((g) => genres[g]).nonNulls.firstOrNull ?? '',
    rating: rating == 0 ? null : rating,
    posterUrl: poster == null ? null : '$_imageBase/w342$poster',
    backdropUrl: backdrop == null ? null : '$_imageBase/w780$backdrop',
    overview: (json['overview'] as String?)?.trim().takeIfNotEmpty,
  );
}

/// What a title's watch providers count as watchable: in a subscription, free
/// or with ads (not to rent or buy).
const _watchable = ['flatrate', 'free', 'ads'];

extension on String {
  String? get takeIfNotEmpty => isEmpty ? null : this;
}

/// The calls to TMDB (v3) that the home needs. A call that fails throws a
/// [TmdbError]: [TmdbError.badKey] for a 401, [TmdbError.network] for anything
/// else. An answer that is not shaped like TMDB's fails later, in the parsing,
/// with a plain error. A client is made for one refresh: it asks for each genre
/// list once and keeps it.
class TmdbClient {
  final String key;

  /// A TMDB language tag, such as `en-US` or `pt-BR`.
  final String language;
  final Fetch _fetch;
  final _genres = <MediaType, Map<int, String>>{};

  TmdbClient(this.key, this.language, {this._fetch = getJson});

  /// One call to TMDB, with the key and the language on it.
  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String> query = const {},
  ]) async {
    try {
      return await _fetch(
        Uri.https('api.themoviedb.org', '/3/$path', {
          ...query,
          'api_key': key,
          'language': language,
        }),
      );
    } on HttpStatusException catch (e) {
      throw e.status == 401 ? TmdbError.badKey : TmdbError.network;
    } catch (_) {
      throw TmdbError.network;
    }
  }

  /// The week's trending titles, 20 of them.
  Future<List<MediaItem>> trending(MediaType type) =>
      _list('trending/${_kind(type)}/week', type);

  /// The most popular titles right now, 20 of them.
  Future<List<MediaItem>> popular(MediaType type) =>
      _list('${_kind(type)}/popular', type);

  /// What TMDB suggests to a person who liked [item], 20 titles at most.
  Future<List<MediaItem>> recommendations(MediaItem item) =>
      _list('${_kind(item.type)}/${item.id}/recommendations', item.type);

  /// TMDB's best rated titles of all time, 20 of them.
  Future<List<MediaItem>> topRated(MediaType type) =>
      _list('${_kind(type)}/top_rated', type);

  /// Well rated titles that few people voted on (7.5 or more, between 200 and
  /// 2000 votes), the best first; 20 of them.
  Future<List<MediaItem>> hiddenGems(MediaType type) =>
      _list('discover/${_kind(type)}', type, {
        'vote_average.gte': '7.5',
        'vote_count.gte': '200',
        'vote_count.lte': '2000',
        'sort_by': 'vote_average.desc',
      });

  /// The most popular titles of the genre [genreId], 20 of them.
  Future<List<MediaItem>> discoverGenre(MediaType type, int genreId) => _list(
    'discover/${_kind(type)}',
    type,
    {'with_genres': '$genreId', 'sort_by': 'popularity.desc'},
  );

  /// One film genre for [day], id and name: the ids in order, picked by the
  /// day of the year, so it changes daily and is the same all day. Null when
  /// TMDB lists none.
  Future<(int, String)?> genreOfTheDay(DateTime day) async {
    final names = await genres(MediaType.movie);
    if (names.isEmpty) return null;
    final ids = names.keys.toList()..sort();
    // In UTC, so a daylight saving change does not shift the count.
    final dayOfYear =
        DateTime.utc(
          day.year,
          day.month,
          day.day,
        ).difference(DateTime.utc(day.year)).inDays +
        1;
    final id = ids[dayOfYear % ids.length];
    return (id, names[id]!);
  }

  /// The names of the genres by id, for films or for series.
  Future<Map<int, String>> genres(MediaType type) async {
    final known = _genres[type];
    if (known != null) return known;
    final json = await _get('genre/${_kind(type)}/list');
    return _genres[type] = {
      for (final g in json['genres'] as List)
        g['id'] as int: g['name'] as String,
    };
  }

  /// Null when TMDB has none.
  Future<String?> imdbId(MediaItem item) async {
    final json = await _get('${_kind(item.type)}/${item.id}/external_ids');
    final id = json['imdb_id'] as String?;
    return id == null || id.isEmpty ? null : id;
  }

  /// [item] under TMDB's id: as it is, or for a Stremio title (an IMDb id)
  /// the one [findByImdb] finds; null when TMDB has none.
  Future<MediaItem?> known(MediaItem item) async =>
      item.id.startsWith('tt') ? findByImdb(item.imdbId ?? item.id) : item;

  /// The services where [item] (under TMDB's id) can be watched in
  /// [country], in subscription, free, then with-ads order.
  Future<List<WatchProvider>> watchProviders(
    MediaItem item,
    String country,
  ) async {
    final json = await _get('${_kind(item.type)}/${item.id}/watch/providers');
    final here = (json['results'] as Map?)?[country] as Map? ?? const {};
    final seen = <int>{};
    return [
      for (final kind in _watchable)
        for (final p in here[kind] as List? ?? const [])
          if (seen.add(p['provider_id'] as int))
            WatchProvider(
              p['provider_id'] as int,
              p['provider_name'] as String,
              null,
            ),
    ];
  }

  /// The film or series that TMDB has under an IMDb id; null if it has neither.
  Future<MediaItem?> findByImdb(String imdbId) async {
    final json = await _get('find/$imdbId', {'external_source': 'imdb_id'});
    for (final (field, type) in [
      ('movie_results', MediaType.movie),
      ('tv_results', MediaType.series),
    ]) {
      final found = json[field] as List? ?? const [];
      if (found.isNotEmpty) return _item(found.first, type, await genres(type));
    }
    return null;
  }

  /// A title by its TMDB [id], as the rows have it (its genre named); null
  /// when TMDB has no such title.
  Future<MediaItem?> details(MediaType type, String id) async {
    final names = await genres(type);
    final json = await _get('${_kind(type)}/$id');
    return _item(
      {
        ...json,
        'id': id,
        'genre_ids': [
          for (final g in json['genres'] as List? ?? const []) g['id'],
        ],
      },
      type,
      names,
    );
  }

  /// The YouTube key of a trailer TMDB lists for [item], else of a teaser;
  /// null when it has neither on YouTube. Videos in the client's language, in
  /// English and in none are asked for, and among those of a kind the client's
  /// language comes first, then TMDB's order.
  Future<String?> trailer(MediaItem item) async {
    // TMDB keeps only videos in `language` unless told more.
    final lang = language.split('-').first;
    final json = await _get('${_kind(item.type)}/${item.id}/videos', {
      'include_video_language': '$lang,en,null',
    });
    final videos = [
      for (final v in json['results'] as List? ?? const [])
        if (v['site'] == 'YouTube') v,
    ];
    for (final type in ['Trailer', 'Teaser']) {
      final ofType = videos.where((v) => v['type'] == type);
      final video =
          ofType.where((v) => v['iso_639_1'] == lang).firstOrNull ??
          ofType.firstOrNull;
      if (video != null) return video['key'] as String?;
    }
    return null;
  }

  /// The title's logo (the wordmark on its posters) as a w500 PNG URL, in the
  /// client's language if TMDB has one, else English, else any; null without.
  Future<String?> logo(MediaItem item) async {
    final lang = language.split('-').first;
    final json = await _get('${_kind(item.type)}/${item.id}/images', {
      'include_image_language': '$lang,en,null',
    });
    final logos = [
      for (final l in json['logos'] as List? ?? const [])
        if (l['file_path'] is String) l,
    ];
    final logo =
        logos.where((l) => l['iso_639_1'] == lang).firstOrNull ??
        logos.where((l) => l['iso_639_1'] == 'en').firstOrNull ??
        logos.firstOrNull;
    return logo == null ? null : '$_imageBase/w500${logo['file_path']}';
  }

  /// The titles TMDB finds for [query], 20 at most; no adult ones.
  Future<List<MediaItem>> search(MediaType type, String query) => _list(
    'search/${_kind(type)}',
    type,
    {'query': query, 'include_adult': 'false'},
  );

  Future<List<MediaItem>> _list(
    String path,
    MediaType type, [
    Map<String, String> query = const {},
    bool Function(Map)? keep,
  ]) async {
    final names = await genres(type);
    final json = await _get(path, query);
    return [
      for (final r in json['results'] as List)
        if (keep == null || keep(r)) ?_item(r, type, names),
    ];
  }

  /// The week's trending films that can be watched at home on [today] (out
  /// on digital or disc), in trending order, then the most popular of those
  /// out at home in the last year; 20. Stremio finds sources for these, not
  /// for a film only in cinemas. When that list fails, the trending films
  /// already out at all.
  Future<List<MediaItem>> trendingAtHome(DateTime today) async {
    final trending = await _list(
      'trending/movie/week',
      MediaType.movie,
      const {},
      (r) => _out(r, today),
    );
    final List<MediaItem> atHome;
    try {
      final query = {
        'sort_by': 'popularity.desc',
        'with_release_type': '4|5',
        'release_date.lte': _day(today),
        'release_date.gte': _day(today.subtract(const Duration(days: 365))),
      };
      atHome = [
        for (final page in ['1', '2'])
          ...await _list('discover/movie', MediaType.movie, {
            ...query,
            'page': page,
          }),
      ];
    } catch (_) {
      return trending;
    }
    final ids = {for (final i in atHome) i.id};
    final first = [
      for (final i in trending)
        if (ids.contains(i.id)) i,
    ];
    final shown = {for (final i in first) i.id};
    return [
      ...first,
      for (final i in atHome)
        if (shown.add(i.id)) i,
    ].take(20).toList();
  }

  /// The week's trending series that have started by [today].
  Future<List<MediaItem>> trendingStarted(DateTime today) => _list(
    'trending/tv/week',
    MediaType.series,
    const {},
    (r) => _out(r, today),
  );
}

/// `YYYY-MM-DD`, as TMDB writes dates.
String _day(DateTime d) =>
    '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')}';

/// A list entry released (or first aired) by [today]; one with no date is
/// not out.
bool _out(Map r, DateTime today) {
  final date = (r['release_date'] ?? r['first_air_date']) as String? ?? '';
  return date.isNotEmpty && date.compareTo(_day(today)) <= 0;
}

/// The first of each list, then the second of each, and so on; a list that runs
/// out drops out of the turns.
List<T> inTurns<T>(List<List<T>> lists) => [
  for (var i = 0; lists.any((l) => i < l.length); i++)
    for (final l in lists)
      if (i < l.length) l[i],
];

/// An item as the highlight shows it, its logo's URL if it has one, and the
/// services it can be watched on (asked only in streaming-apps mode).
typedef About = ({MediaItem item, String? logo, List<WatchProvider> providers});

About _plain(MediaItem item) => (item: item, logo: null, providers: const []);

/// The films and series of the home: the popular ones (Stremio's, else TMDB's
/// trending of the week), and a row of recommendations. The last answer is cached on disk, so the home opens with
/// it; the open app asks again every 6 hours.
class TmdbSource extends ChangeNotifier {
  final Settings settings;
  final Store store;
  final Fetch _fetch;
  final JustWatchClient _justWatch;
  Timer? _timer;

  List<MediaItem> movies = [];
  List<MediaItem> series = [];
  List<MediaItem> recommended = [];

  /// What is wrong with the rows; null when the last refresh went well or none
  /// has run. The rows are whatever the cache and the last good refresh gave,
  /// whatever the error.
  TmdbError? error;

  /// IMDb ids of titles the person watches; the recommendations start from the
  /// first five.
  List<String> seeds = [];

  TmdbSource(
    this.settings,
    this.store, {
    this._fetch = getJson,
    Post post = postJson,
  }) : _justWatch = JustWatchClient(post),
       _rows = '' {
    _rows = _rowsNow;
    settings.addListener(_settingsChanged);
  }

  /// What the rows were made for: [_rowsNow] when they were asked.
  String _rows;

  /// Where the rows come from: the country and, per kind, [_from].
  String get _rowsNow =>
      '${settings.country}/${_from(MediaType.movie)}/${_from(MediaType.series)}';

  /// Where the row of [type] comes from: `stremio` (Cinemeta's ranking) in
  /// Stremio mode; in streaming-apps mode the mapped services' ids,
  /// `|`-joined (JustWatch's charts of those), or '' with none mapped
  /// (TMDB's trending).
  String _from(MediaType type) {
    final provider = type == MediaType.movie
        ? settings.movieProvider
        : settings.seriesProvider;
    if (provider.isNotEmpty) return 'stremio';
    return ([
      for (final MapEntry(:key, :value) in settings.serviceApps.entries)
        if (value.isNotEmpty) key,
    ]..sort()).join('|');
  }

  /// A new country, mode or mapping: the rows and the highlights are asked
  /// again.
  void _settingsChanged() {
    final rows = _rowsNow;
    if (rows == _rows) return;
    _rows = rows;
    _abouts.clear();
    _known.clear();
    if (settings.tmdbKey.isEmpty) return;
    // Mapping one service after another: one refresh out, then one more for
    // the last mapping, not one each.
    if (_changing != null) {
      _changedAgain = true;
      return;
    }
    _changing = () async {
      do {
        _changedAgain = false;
        await refresh(force: true);
      } while (_changedAgain);
    }().whenComplete(() => _changing = null)..ignore();
  }

  Future<void>? _changing;
  var _changedAgain = false;

  /// The streaming services of [region], from the cache or the last refresh;
  /// none until one of those.
  List<WatchProvider> providers = [];

  /// What is popular in [region] now, films and series together (JustWatch's
  /// charts), for the home's first fold; from the cache or the last refresh.
  List<MediaItem> popular = [];

  /// JustWatch's genres, named in the app's language, from the cache or the
  /// last refresh; the rows can be filtered by one.
  List<Genre> genres = [];

  /// The region the services and their rows are asked for.
  String get region => settings.country;

  /// A service's row as loaded this run, by its cache key; see [providerRow].
  final _providerRows = <String, List<MediaItem>>{};
  final _loadingRows = <String, Future<void>>{};

  /// The store's service rows, read once: the loads share the one map, so a
  /// write by one keeps the entry another put there meanwhile.
  Future<Map<String, dynamic>>? _providerEntries;

  String _rowKey(MediaType type, int? service, String? genre) =>
      '$region|${settings.tmdbLanguage}|${_kind(type)}|'
      '${service ?? _from(type)}|${genre ?? ''}';

  /// The JustWatch short names of the services a row of [type] is asked
  /// for: [service]'s alone, else in streaming-apps mode the mapped ones that
  /// [known] has; none is every service.
  List<String> _packages(
    MediaType type,
    int? service, [
    List<WatchProvider>? known,
  ]) {
    final from = _from(type);
    final ids = service != null
        ? {'$service'}
        : from == 'stremio'
        ? const <String>{}
        : from.split('|').toSet();
    return [
      for (final p in known ?? providers)
        if (ids.contains('${p.id}')) p.key,
    ];
  }

  /// What is popular now on [packages] (every service with none) and in
  /// [genre], as TMDB has each title.
  Future<List<MediaItem>> _charts(
    TmdbClient tmdb,
    MediaType type,
    List<String> packages,
    String? genre,
  ) async => _asTmdb(
    tmdb,
    await _justWatch.popularOn(
      region,
      settings.language,
      type,
      await tmdb.genres(type),
      services: packages,
      genre: genre,
    ),
  );

  /// What [providerRow] has brought in this run for the service [service]
  /// and the genre [genre]; null before it answers.
  List<MediaItem>? providerRowNow(
    MediaType type, {
    int? service,
    String? genre,
  }) => _providerRows[_rowKey(type, service, genre)];

  /// [items] as TMDB has each (text, pictures, genre), by their ids, five
  /// at a time; one TMDB fails on stays as JustWatch gave it. JustWatch's
  /// own backdrops looked poor on the TV; TMDB's are the other rows'.
  Future<List<MediaItem>> _asTmdb(
    TmdbClient tmdb,
    List<MediaItem> items,
  ) async {
    final out = List.of(items);
    for (var i = 0; i < out.length; i += 5) {
      await Future.wait([
        for (var j = i; j < i + 5 && j < out.length; j++)
          tmdb
              .details(out[j].type, out[j].id)
              .then((d) => d == null ? null : out[j] = d, onError: (_) {}),
      ]);
    }
    return out;
  }

  Future<Map<String, dynamic>> _readProviderEntries() async {
    try {
      return await store.read(_rowsCache) ?? {};
    } catch (_) {
      return {};
    }
  }

  /// Brings in the row of the service [service] (in streaming-apps mode, of
  /// the mapped ones with none) and the genre [genre]: from the store's entry
  /// while it is under 6 hours old (shown at once even when older), else from
  /// TMDB, which then replaces the entry. Listeners hear each arrival. A
  /// failure leaves what is known; a second call while one is under way
  /// joins it.
  Future<void> providerRow(MediaType type, {int? service, String? genre}) {
    final key = _rowKey(type, service, genre);
    // A block: an arrow would hand whenComplete the removed future, its own,
    // to wait for.
    return _loadingRows[key] ??= _loadProviderRow(key, type, service, genre)
        .whenComplete(() {
          _loadingRows.remove(key);
        });
  }

  Future<void> _loadProviderRow(
    String key,
    MediaType type,
    int? serviceId,
    String? genre,
  ) async {
    final entries = await (_providerEntries ??= _readProviderEntries());
    try {
      if (entries[key] case {
        'at': final String at,
        'items': final List items,
      }) {
        if (!_providerRows.containsKey(key)) {
          _providerRows[key] = [for (final j in items) MediaItem.fromJson(j)];
          notifyListeners();
        }
        final age = DateTime.now().difference(
          DateTime.tryParse(at) ?? DateTime(0),
        );
        if (!age.isNegative && age < _every) return;
      }
    } catch (_) {}
    if (settings.tmdbKey.isEmpty) return;
    // The service's JustWatch name comes with the list; a service the
    // region's list no longer has gets no row (the home shows All). A genre
    // alone needs no service.
    final packages = _packages(type, serviceId);
    if (serviceId != null && packages.isEmpty) return;
    try {
      final items = await _charts(client, type, packages, genre);
      _providerRows[key] = items;
      notifyListeners();
      entries[key] = {
        'at': DateTime.now().toUtc().toIso8601String(),
        'items': [for (final i in items) i.toJson()],
      };
      await store.write(_rowsCache, entries);
    } catch (_) {}
  }

  /// Whether TMDB can be asked about [item]: a film or series under a TMDB
  /// id or an IMDb one (Stremio's), with a key to ask with.
  bool _asks(MediaItem item) =>
      settings.tmdbKey.isNotEmpty &&
      (item.type == MediaType.movie || item.type == MediaType.series) &&
      (item.id.startsWith('tt') || int.tryParse(item.id) != null);

  /// What the highlight shows of [item]: the item with TMDB's year, genre,
  /// rating and synopsis where it had none (a Stremio title, found by its
  /// IMDb id), its logo URL (see [TmdbClient.logo]) and, in streaming-apps
  /// mode with a service mapped, its [providersFor]. Asked once per run (and
  /// again after a change of country, mode or mapping) and kept; a failed
  /// call answers the item as it is and is asked again.
  Future<About> about(MediaItem item) {
    if (!_asks(item)) return Future.value(_plain(item));
    return _abouts.putIfAbsent(item.key, () async {
      try {
        final known = await client.known(item);
        if (known == null) return _known[item.key] = _plain(item);
        final from = _from(item.type);
        final (logo, providers) = await (
          client.logo(known),
          from.isEmpty || from == 'stremio'
              ? Future.value(const <WatchProvider>[])
              : providersFor(item, known: known),
        ).wait;
        return _known[item.key] = (
          item: item.filledFrom(known),
          logo: logo,
          providers: providers,
        );
      } catch (_) {
        _abouts.remove(item.key);
        return _plain(item);
      }
    });
  }

  /// [about]'s answer when it is already here (at once for an item TMDB is
  /// not asked about); null while it is on its way.
  About? aboutNow(MediaItem item) =>
      _asks(item) ? _known[item.key] : _plain(item);

  final _abouts = <String, Future<About>>{};
  final _known = <String, About>{};

  /// Shows what the last run cached, of any age and in any language: the first
  /// [refresh] replaces it when it is due. A cache this version cannot read is
  /// skipped as a whole.
  Future<void> loadCache() async {
    try {
      final cached = await store.read(_cache);
      if (cached == null) return;
      // A list the cache was written without (an older shape) is empty.
      List<MediaItem> items(String key) => [
        for (final json in cached[key] as List? ?? const [])
          MediaItem.fromJson(json),
      ];
      final cachedMovies = items('movies');
      final cachedSeries = items('series');
      final cachedRecommended = items('recommended');
      // The services and the popular titles only for the region they were
      // asked for.
      final sameRegion = cached['region'] == region;
      final cachedProviders = sameRegion
          ? [
              for (final j in cached['providers'] as List? ?? const [])
                WatchProvider.fromJson(j),
            ]
          : <WatchProvider>[];
      final cachedPopular = sameRegion ? items('popular') : <MediaItem>[];
      // The genres go with the language, which the cache is checked on.
      final cachedGenres = [
        for (final j in cached['genres'] as List? ?? const [])
          Genre.fromJson(j),
      ];
      movies = cachedMovies;
      series = cachedSeries;
      recommended = cachedRecommended;
      providers = cachedProviders;
      popular = cachedPopular;
      genres = cachedGenres;
      notifyListeners();
    } catch (_) {}
  }

  /// Asks TMDB, unless there are rows to show and the cache holds rows in the
  /// language of Settings that are under 6 hours old; [force] asks anyway. The
  /// rows are replaced only when every call went well. A failure of any kind
  /// leaves them as they were and sets [error]; the next refresh tries again.
  /// An answer, or a failure, for a key or a language that is no longer the
  /// one in Settings is dropped.
  Future<void> refresh({bool force = false}) async {
    final key = settings.tmdbKey;
    if (key.isEmpty) {
      _setError(TmdbError.noKey);
      return;
    }
    final language = settings.tmdbLanguage;
    final rows = _rowsNow;
    List<MediaItem>? newMovies, newSeries, newRecommended;
    List<WatchProvider>? newProviders;
    List<MediaItem>? newPopular;
    List<Genre>? newGenres;
    var failure = TmdbError.network; // unless the client says why
    try {
      // With nothing to show, the cache is no cache; one of an older shape
      // (from before the synopsis) is asked again.
      if (!force && movies.isNotEmpty) {
        final cached = await store.freshOrNull(_cache, _every);
        if (cached != null &&
            cached['language'] == language &&
            cached['rows'] == rows &&
            cached['shape'] == _shape) {
          return;
        }
      }
      final client = TmdbClient(key, language, fetch: _fetch);
      // The genres first; the rows below reuse them.
      final movieGenres = await client.genres(MediaType.movie);
      final tvGenres = await client.genres(MediaType.series);
      // JustWatch's part is a filter and the first fold, not a row: without
      // it the rows still refresh, and what it gave last stays.
      try {
        newProviders = await _justWatch.services(region);
        newGenres = await _justWatch.genres(settings.language);
        newPopular = await _asTmdb(
          client,
          await _justWatch.popular(
            region,
            settings.language,
            movieGenres,
            tvGenres,
          ),
        );
      } catch (_) {}
      final today = DateTime.now();
      final known = newProviders ?? providers;
      newMovies = await _row(
        client,
        MediaType.movie,
        today,
        known,
        () => client.trendingAtHome(today),
      );
      newSeries = await _row(
        client,
        MediaType.series,
        today,
        known,
        () => client.trendingStarted(today),
      );
      newRecommended = await _recommended(client, {
        for (final i in [...newMovies, ...newSeries]) i.key,
      });
    } on TmdbError catch (e) {
      failure = e;
    } catch (_) {
      // The client could not read TMDB's answer.
      // ponytail: no retry. A failed refresh waits for the next tick or
      // resume; retry once after a few seconds if a TV that boots before its
      // Wi-Fi leaves the rows stale for too long.
    }
    // The key, the language or where the rows come from changed while the
    // calls were out.
    if (settings.tmdbKey != key ||
        settings.tmdbLanguage != language ||
        _rowsNow != rows) {
      return;
    }
    if (newMovies == null || newSeries == null || newRecommended == null) {
      _setError(failure);
      return;
    }
    movies = newMovies;
    series = newSeries;
    recommended = newRecommended;
    providers = newProviders ?? providers;
    popular = newPopular ?? popular;
    genres = newGenres ?? genres;
    error = null;
    notifyListeners();
    // Last, so a cache that will not write (a full disk) cannot undo a good
    // fetch.
    try {
      await store.write(_cache, _cacheJson(language, rows));
    } catch (_) {}
  }

  /// The rows, the services and what they were asked with, as the cache
  /// keeps them.
  Map<String, dynamic> _cacheJson(String language, String rows) => {
    'movies': [for (final i in movies) i.toJson()],
    'series': [for (final i in series) i.toJson()],
    'recommended': [for (final i in recommended) i.toJson()],
    'providers': [for (final p in providers) p.toJson()],
    'popular': [for (final i in popular) i.toJson()],
    'genres': [for (final g in genres) g.toJson()],
    'region': region,
    'language': language,
    'rows': rows,
    'shape': _shape,
  };

  void _setError(TmdbError e) {
    if (error == e) return;
    error = e;
    notifyListeners();
  }

  /// For a key that was removed: the rows go, and with them the caches, so
  /// they do not come back on the next start. A cache that will not go is
  /// left.
  Future<void> clear() async {
    movies = [];
    series = [];
    recommended = [];
    error = TmdbError.noKey;
    for (final name in [_cache, _imdbCache, _providersCache]) {
      try {
        await store.delete(name);
      } catch (_) {}
    }
    notifyListeners();
  }

  /// The row of [type], from where [_from] says: Cinemeta's ranking, what
  /// is popular on the mapped services of [known], or [otherwise] (TMDB's
  /// trending), also when JustWatch fails or has nothing for them.
  Future<List<MediaItem>> _row(
    TmdbClient client,
    MediaType type,
    DateTime today,
    List<WatchProvider> known,
    Future<List<MediaItem>> Function() otherwise,
  ) async {
    final from = _from(type);
    if (from == 'stremio') return _popular(client, type, today, otherwise);
    final packages = _packages(type, null, known);
    if (packages.isEmpty) return otherwise();
    try {
      final items = await _charts(client, type, packages, null);
      if (items.isNotEmpty) return items;
    } catch (_) {}
    return otherwise();
  }

  /// The 20 most popular titles of a kind in Stremio (Cinemeta's `top`
  /// catalog, no key) that are out by [today], each as TMDB has it under its
  /// IMDb id: TMDB's language, images and ids. [otherwise] when Cinemeta does
  /// not answer or TMDB knows none of them.
  Future<List<MediaItem>> _popular(
    TmdbClient client,
    MediaType type,
    DateTime today,
    Future<List<MediaItem>> Function() otherwise,
  ) async {
    final List<String> ids;
    try {
      final kind = type == MediaType.movie ? 'movie' : 'series';
      final json = await _fetch(
        Uri.parse('https://v3-cinemeta.strem.io/catalog/$kind/top.json'),
      );
      ids = [
        for (final m in json['metas'] as List)
          if (m['id'] case final String id when id.startsWith('tt'))
            if (m['released'] case final String date
                when date.isNotEmpty && date.compareTo(_day(today)) <= 0)
              id,
      ].take(20).toList();
    } catch (_) {
      return otherwise();
    }
    final found = (await Future.wait(ids.map(client.findByImdb))).nonNulls
        .where((i) => i.type == type)
        .toList();
    return found.isEmpty ? otherwise() : found;
  }

  /// Up to 20 titles for the recommendations: what TMDB suggests after each of
  /// the first five [seeds], one seed after the other in turn; a seed that TMDB
  /// does not know, or that fails, adds nothing. When the seeds give nothing,
  /// the popular films and series, in turn. A title that is among [taken] (the
  /// keys on the other rows) or came before is left out.
  Future<List<MediaItem>> _recommended(
    TmdbClient client,
    Set<String> taken,
  ) async {
    List<MediaItem> pick(List<List<MediaItem>> lists) {
      final seen = {...taken};
      return [
        for (final item in inTurns(lists))
          if (seen.add(item.key)) item,
      ].take(20).toList();
    }

    final lists = <List<MediaItem>>[];
    for (final seed in seeds.take(5).toList()) {
      try {
        final item = await client.findByImdb(seed);
        if (item != null) lists.add(await client.recommendations(item));
      } catch (e) {
        if (e == TmdbError.badKey) rethrow; // the key is no seed's fault
        // ponytail: any other failure skips the seed, so after a bad moment
        // of network the row may be the popular one for 6 hours; skip the
        // cache write when every seed failed if that shows.
      }
    }
    final fromSeeds = pick(lists);
    if (fromSeeds.isNotEmpty) return fromSeeds;
    return pick([
      await client.popular(MediaType.movie),
      await client.popular(MediaType.series),
    ]);
  }

  /// Redoes only the recommendations, from the current [seeds], and writes
  /// them to the cache beside the rows as they are; [movies] and [series] stay
  /// as they were. Nothing to do without a key, or while there are no rows to
  /// take titles from: the first [refresh] makes them, with the seeds. A
  /// failure is mapped as in [refresh] and leaves the row as it was, and an
  /// answer for a key or a language that changed meanwhile is dropped, as in
  /// [refresh].
  Future<void> refreshRecommended() async {
    final key = settings.tmdbKey;
    if (key.isEmpty || movies.isEmpty && series.isEmpty) return;
    // ponytail: the language of Settings, even if the rows came in another; a
    // language switch is followed by a forced refresh that redoes all three.
    final language = settings.tmdbLanguage;
    final rows = _rowsNow;
    List<MediaItem>? newRecommended;
    var failure = TmdbError.network;
    try {
      newRecommended = await _recommended(
        TmdbClient(key, language, fetch: _fetch),
        {
          for (final i in [...movies, ...series]) i.key,
        },
      );
    } on TmdbError catch (e) {
      failure = e;
    } catch (_) {}
    if (settings.tmdbKey != key ||
        settings.tmdbLanguage != language ||
        _rowsNow != rows) {
      return;
    }
    if (newRecommended == null) {
      _setError(failure);
      return;
    }
    recommended = newRecommended;
    error = null;
    notifyListeners();
    try {
      await store.write(_cache, _cacheJson(language, rows));
    } catch (_) {}
  }

  /// A client for the key and the language in Settings now.
  TmdbClient get client =>
      TmdbClient(settings.tmdbKey, settings.tmdbLanguage, fetch: _fetch);

  /// Refreshes at once, if due, and then every 6 hours. Safe to call again.
  void start() {
    refresh();
    // The tick forces: it comes just under 6 hours after the cache was
    // written, which would still count as fresh.
    _timer ??= Timer.periodic(_every, (_) => refresh(force: true));
  }

  /// Safe without a [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// The IMDb id of a TMDB [item], which is what Stremio opens a title by.
  /// TMDB's answer is remembered for 7 days, "none" included. When TMDB cannot
  /// be asked, or the cache cannot take the answer, what is known stands: the
  /// remembered id, however old, or null.
  Future<String?> imdbIdFor(MediaItem item) async {
    if (item.imdbId != null) return item.imdbId;
    String? answer;
    try {
      final known = await store.read(_imdbCache) ?? <String, dynamic>{};
      if (known[item.key] case {
        'imdbId': String? id,
        'savedAt': String saved,
      }) {
        answer = id;
        final at = DateTime.tryParse(saved);
        final age = at == null ? null : DateTime.now().difference(at);
        if (age != null && !age.isNegative && age < _imdbEvery) return id;
      }
      if (settings.tmdbKey.isEmpty) return answer;
      answer = await client.imdbId(item);
      // ponytail: old entries stay in the file; prune them if it ever grows
      // into a nuisance (an entry is about 80 bytes).
      known[item.key] = {
        'imdbId': answer,
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await store.write(_imdbCache, known);
    } catch (_) {}
    return answer;
  }

  /// The services [item] can be watched on in [Settings.country]
  /// ([TmdbClient.watchProviders]; [known] is the item under TMDB's id when
  /// the caller has it). Remembered for 7 days per country and title; when
  /// TMDB cannot be asked, what is known stands: the remembered answer,
  /// however old, or none.
  Future<List<WatchProvider>> providersFor(
    MediaItem item, {
    MediaItem? known,
  }) async {
    if (item.type != MediaType.movie && item.type != MediaType.series) {
      return const [];
    }
    final key = '${settings.country}/${item.key}';
    var answer = const <WatchProvider>[];
    try {
      final cache = await store.read(_providersCache) ?? <String, dynamic>{};
      if (cache[key] case {'providers': List had, 'savedAt': String saved}) {
        answer = [for (final p in had) WatchProvider.fromJson(p as Map)];
        final at = DateTime.tryParse(saved);
        final age = at == null ? null : DateTime.now().difference(at);
        if (age != null && !age.isNegative && age < _imdbEvery) return answer;
      }
      if (settings.tmdbKey.isEmpty) return answer;
      final tmdbItem = known ?? await client.known(item);
      answer = tmdbItem == null
          ? const []
          : await client.watchProviders(tmdbItem, settings.country);
      cache[key] = {
        'providers': [
          for (final p in answer) {'id': p.id, 'name': p.name},
        ],
        'savedAt': DateTime.now().toUtc().toIso8601String(),
      };
      if (cache.length > kProvidersKept) {
        String saved(String k) => '${(cache[k] as Map?)?['savedAt']}';
        final oldest = cache.keys.toList()
          ..sort((a, b) => saved(a).compareTo(saved(b)));
        oldest.take(cache.length - kProvidersKept).forEach(cache.remove);
      }
      await store.write(_providersCache, cache);
    } catch (_) {}
    return answer;
  }
}
