import '../net.dart';
import 'media.dart';

const _api = 'https://apis.justwatch.com/graphql';
const _images = 'https://images.justwatch.com';

/// A streaming service as JustWatch lists it: TMDB's provider id (the same
/// number), its name, its logo, and [key], the short name JustWatch filters
/// by (`nfx` for Netflix).
class WatchProvider {
  final int id;
  final String name;
  final String? logoUrl;
  final String key;
  const WatchProvider(this.id, this.name, this.logoUrl, {this.key = ''});

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'logoUrl': logoUrl,
    'key': key,
  };

  factory WatchProvider.fromJson(Map json) => WatchProvider(
    (json['id'] as num).toInt(),
    json['name'] as String,
    json['logoUrl'] as String?,
    key: json['key'] as String? ?? '',
  );
}

/// A genre as JustWatch lists it: its [code] (`cmy`), which its filters
/// take, and its [name] in a language.
class Genre {
  final String code;
  final String name;
  const Genre(this.code, this.name);

  Map<String, dynamic> toJson() => {'code': code, 'name': name};

  factory Genre.fromJson(Map json) =>
      Genre(json['code'] as String, json['name'] as String);
}

/// The services the rows can be filtered by: subscriptions, by id. A
/// country's list has stores (the Apple TV store) and free services
/// (JustWatch TV Free, Tubi) among them, which are not what the row is for.
/// A country's missing service is added here.
const _subscriptions = {
  8, // Netflix
  9, 119, // Prime Video (US; elsewhere)
  337, 390, // Disney+
  350, // Apple TV, once Apple TV+ (2 is the store)
  1899, 384, // Max; HBO Max
  531, // Paramount+
  15, // Hulu
  386, // Peacock
  230, // Crave
  307, 227, // Globoplay; Telecine
  283, // Crunchyroll
  11, // MUBI
  619, // Star+
  510, 524, // Discovery+ (US; elsewhere)
  381, // Canal+
  39, 29, 151, // Now, Sky Go, BritBox
  21, 385, // Stan, Binge
  122, // Hotstar
  76, 1773, // Viaplay, SkyShowtime
};

/// JustWatch's genre codes as TMDB's genre ids (film, series), for the names
/// TMDB gives in the UI language; a code with no genre of the kind gives way
/// to the title's next one.
const _genreIds = <String, (int?, int?)>{
  'act': (28, 10759),
  'ani': (16, 16),
  'cmy': (35, 35),
  'crm': (80, 80),
  'doc': (99, 99),
  'drm': (18, 18),
  'fml': (10751, 10751),
  'fnt': (14, 10765),
  'hst': (36, null),
  'hrr': (27, null),
  'msc': (10402, null),
  'rma': (10749, null),
  'scf': (878, 10765),
  'trl': (53, 9648),
  'war': (10752, 10768),
  'wsn': (37, 37),
  'rly': (null, 10764),
};

/// JustWatch's own data, from the GraphQL its site uses (no key, not
/// documented): a country's streaming services, and what is popular on each
/// there now by its streaming charts. The service ids are TMDB's, and each
/// title carries its TMDB id, so everything after the row stays with TMDB.
class JustWatchClient {
  final Post _post;
  const JustWatchClient([this._post = postJson]);

  Future<Map<String, dynamic>> _ask(
    String operation,
    String query,
    Map<String, dynamic> variables,
  ) => _post(Uri.parse(_api), {
    'operationName': operation,
    'variables': variables,
    'query': query,
  });

  /// The subscription services of [country] (ISO 3166-1 alpha-2), in
  /// JustWatch's order for it.
  Future<List<WatchProvider>> services(String country) async {
    final json = await _ask('GetProviders', _providersQuery, {
      'country': country,
    });
    final packages = json['data']?['packages'] as List? ?? const [];
    final listed = [
      for (final p in packages)
        if (_subscriptions.contains(p['packageId'])) p,
    ];
    String name(p) => (p['clearName'] as String? ?? '').toLowerCase();
    // The country's other subscriptions after the known ones: not a store
    // (BUY), not ad-funded, not a variant of a listed one (Netflix Kids).
    bool local(p) {
      final types = p['monetizationTypes'] as List? ?? const [];
      return !_subscriptions.contains(p['packageId']) &&
          types.contains('FLATRATE') &&
          !types.contains('BUY') &&
          !types.contains('ADS') &&
          !listed.any((l) => name(p).startsWith(name(l)));
    }

    return [
      for (final p in [...listed, ...packages.where(local)].take(30))
        WatchProvider(
          (p['packageId'] as num).toInt(),
          p['clearName'] as String? ?? '',
          p['icon'] == null ? null : '$_images${p['icon']}',
          key: p['shortName'] as String? ?? '',
        ),
    ];
  }

  /// JustWatch's genres, whole, named in [language] (`en`, `pt`) and in
  /// that order: a card moved one step at a time finds Horror and
  /// Documentary where the eye looks for them.
  Future<List<Genre>> genres(String language) async {
    final json = await _ask('GetGenres', _genresQuery, {'language': language});
    return [
      for (final g in json['data']?['genres'] as List? ?? const [])
        Genre(g['shortName'] as String, g['translation'] as String? ?? ''),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// What is popular in [country] now on [services] (their short names; none
  /// is every service) and in the genre [genre] (its code), in
  /// JustWatch's order: up to 20 titles of [type] with a TMDB id, their text
  /// in [language] (`en`, `pt`), their genre named from TMDB's [genres].
  Future<List<MediaItem>> popularOn(
    String country,
    String language,
    MediaType type,
    Map<int, String> genres, {
    List<String> services = const [],
    String? genre,
  }) => _popular(country, language, {
    if (services.isNotEmpty) 'packages': services,
    if (genre != null) 'genres': [genre],
    'objectTypes': [_kind(type)],
  }, (_) => genres);

  /// The country's popular films and series together, the same way, each
  /// with its own kind's genre names: the home's first fold.
  Future<List<MediaItem>> popular(
    String country,
    String language,
    Map<int, String> movieGenres,
    Map<int, String> tvGenres,
  ) => _popular(country, language, {
    'objectTypes': ['MOVIE', 'SHOW'],
  }, (type) => type == MediaType.movie ? movieGenres : tvGenres);

  Future<List<MediaItem>> _popular(
    String country,
    String language,
    Map<String, dynamic> filter,
    Map<int, String> Function(MediaType) genres,
  ) async {
    final json = await _ask('GetPopularTitles', _popularQuery, {
      'country': country,
      'language': language,
      'first': 25,
      'filter': filter,
    });
    final edges = json['data']?['popularTitles']?['edges'] as List? ?? const [];
    return [for (final e in edges) ?_item(e['node'] as Map, genres)]
        .take(20)
        .toList();
  }

  static String _kind(MediaType type) =>
      type == MediaType.movie ? 'MOVIE' : 'SHOW';
}

MediaItem? _item(Map node, Map<int, String> Function(MediaType) genres) {
  final type = node['objectType'] == 'MOVIE'
      ? MediaType.movie
      : MediaType.series;
  final c = node['content'] as Map? ?? const {};
  final id = (c['externalIds'] as Map?)?['tmdbId'] as String?;
  if (id == null) return null; // everything after the row lives on TMDB ids
  final names = genres(type);
  final codes = [
    for (final g in c['genres'] as List? ?? const [])
      g['shortName'] as String? ?? '',
  ];
  final poster = c['posterUrl'] as String?;
  final backdrop =
      ((c['backdrops'] as List?)?.firstOrNull as Map?)?['backdropUrl']
          as String?;
  final score = (c['scoring'] as Map?)?['tmdbScore'] as num?;
  final overview = (c['shortDescription'] as String?)?.trim();
  return MediaItem(
    type: type,
    id: id,
    title: c['title'] as String? ?? '',
    year: (c['originalReleaseYear'] as num?)?.toInt(),
    genre:
        codes
            .map((k) {
              final ids = _genreIds[k];
              final gid = type == MediaType.movie ? ids?.$1 : ids?.$2;
              return gid == null ? null : names[gid];
            })
            .nonNulls
            .firstOrNull ??
        '',
    rating: score == null || score == 0 ? null : (score * 10).round() / 10,
    posterUrl: poster == null ? null : '$_images$poster',
    backdropUrl: backdrop == null ? null : '$_images$backdrop',
    overview: overview == null || overview.isEmpty ? null : overview,
  );
}

const _genresQuery = r'''
query GetGenres($language: Language!) {
  genres { shortName translation(language: $language) }
}''';

const _providersQuery = r'''
query GetProviders($country: Country!) {
  packages(country: $country, platform: WEB, includeAddons: false) {
    packageId clearName shortName icon(profile: S100, format: PNG) monetizationTypes
  }
}''';

/// Posters at 332 px (the rows decode them at 192), backdrops at 1440: the
/// home bakes one at the screen's size, and 640 was soft there.
const _popularQuery = r'''
query GetPopularTitles($country: Country!, $language: Language!, $first: Int!, $filter: TitleFilter) {
  popularTitles(country: $country, filter: $filter, first: $first, sortBy: POPULAR, sortRandomSeed: 0) {
    edges { node { objectType content(country: $country, language: $language) {
      title originalReleaseYear shortDescription genres { shortName } externalIds { tmdbId }
      posterUrl(profile: S332, format: JPG) backdrops(profile: S1440, format: JPG) { backdropUrl }
      scoring { tmdbScore }
    } } }
  }
}''';
