/// What a tile is: a film or a series (from TMDB or from the Stremio library),
/// a YouTube video, a game (from ESPN or TheSportsDB), or one of the TV's HDMI
/// inputs (its id, its label for the title, its device name for the genre).
enum MediaType { movie, series, video, game, input }

/// One side of a [Game].
class GameTeam {
  final String id;

  /// The full name ("Boston Celtics"), the short one ("Celtics") and the
  /// abbreviation ("BOS").
  final String name;
  final String short;
  final String abbr;
  final String? logo;

  /// `RRGGBB`, when ESPN gives one.
  final String? color;

  /// Null before the game.
  final String? score;

  const GameTeam({
    required this.id,
    required this.name,
    required this.short,
    required this.abbr,
    this.logo,
    this.color,
    this.score,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'short': short,
    'abbr': abbr,
    'logo': logo,
    'color': color,
    'score': score,
  };

  factory GameTeam.fromJson(Map json) => GameTeam(
    id: json['id'] as String,
    name: json['name'] as String,
    short: json['short'] as String,
    abbr: json['abbr'] as String,
    logo: json['logo'] as String?,
    color: json['color'] as String?,
    score: json['score'] as String?,
  );
}

/// What a game tile knows of its game.
class Game {
  /// Where it came from, as ESPN's `<sport>/<league>`: `soccer/eng.1`,
  /// `basketball/nba`.
  final String league;

  /// In UTC.
  final DateTime start;

  /// ESPN's `pre`, `in` or `post`.
  final String state;

  /// ESPN's short status, such as "67'" or "HT"; empty when unknown.
  final String detail;
  final GameTeam home;
  final GameTeam away;

  const Game({
    required this.league,
    required this.start,
    required this.state,
    this.detail = '',
    required this.home,
    required this.away,
  });

  bool get live => state == 'in';
  String get sport => league.split('/').first;

  Map<String, dynamic> toJson() => {
    'league': league,
    'start': start.toUtc().toIso8601String(),
    'state': state,
    'detail': detail,
    'home': home.toJson(),
    'away': away.toJson(),
  };

  factory Game.fromJson(Map json) => Game(
    league: json['league'] as String,
    start: DateTime.parse(json['start'] as String),
    state: json['state'] as String,
    detail: json['detail'] as String? ?? '',
    home: GameTeam.fromJson(json['home'] as Map),
    away: GameTeam.fromJson(json['away'] as Map),
  );
}

/// One tile of a content row. Immutable; the sources build them and the cache
/// keeps them as JSON.
class MediaItem {
  final MediaType type;

  /// TMDB: the numeric id, as text. Stremio: its `_id`. YouTube: the video id.
  final String id;
  final String title;
  final int? year;

  /// Empty when unknown.
  final String genre;
  final double? rating;
  final String? posterUrl;
  final String? backdropUrl;

  /// What Stremio opens an item by; TMDB's items get it on demand.
  final String? imdbId;

  /// The episode a Stremio series resumes at (`ttX:S:E`), or the YouTube
  /// video.
  final String? videoId;

  /// A line under the title, such as "S2 · E5".
  final String? subtitle;

  /// How much of a YouTube video was watched, 0–1, when YouTube says.
  final double? progress;

  /// A [MediaType.game]'s game; its [genre] is the competition.
  final Game? game;

  /// TMDB's synopsis, a sentence or three; the highlight shows two lines.
  final String? overview;

  const MediaItem({
    required this.type,
    required this.id,
    required this.title,
    this.year,
    this.genre = '',
    this.rating,
    this.posterUrl,
    this.backdropUrl,
    this.imdbId,
    this.videoId,
    this.subtitle,
    this.progress,
    this.game,
    this.overview,
  });

  /// This item with what it lacks of [other]'s year, genre, rating, backdrop
  /// and synopsis: a Stremio title filled in from TMDB's.
  MediaItem filledFrom(MediaItem other) => MediaItem(
    type: type,
    id: id,
    title: title,
    year: year ?? other.year,
    genre: genre.isEmpty ? other.genre : genre,
    rating: rating ?? other.rating,
    posterUrl: posterUrl,
    backdropUrl: backdropUrl ?? other.backdropUrl,
    imdbId: imdbId,
    videoId: videoId,
    subtitle: subtitle,
    progress: progress,
    game: game,
    overview: overview ?? other.overview,
  );

  /// Unique across the types: a movie and a series can share a TMDB id.
  String get key => '${type.name}:$id';

  Map<String, dynamic> toJson() => {
    'type': type.name,
    'id': id,
    'title': title,
    'year': year,
    'genre': genre,
    'rating': rating,
    'posterUrl': posterUrl,
    'backdropUrl': backdropUrl,
    'imdbId': imdbId,
    'videoId': videoId,
    'subtitle': subtitle,
    'progress': ?progress,
    'game': ?game?.toJson(),
    'overview': ?overview,
  };

  /// Numbers are read as `num`, and a missing optional key as null (or, for
  /// the genre, empty), so a cache written by hand loads.
  factory MediaItem.fromJson(Map json) => MediaItem(
    type: MediaType.values.byName(json['type'] as String),
    id: json['id'] as String,
    title: json['title'] as String,
    year: (json['year'] as num?)?.toInt(),
    genre: json['genre'] as String? ?? '',
    rating: (json['rating'] as num?)?.toDouble(),
    posterUrl: json['posterUrl'] as String?,
    backdropUrl: json['backdropUrl'] as String?,
    imdbId: json['imdbId'] as String?,
    videoId: json['videoId'] as String?,
    subtitle: json['subtitle'] as String?,
    progress: (json['progress'] as num?)?.toDouble(),
    game: json['game'] == null ? null : Game.fromJson(json['game'] as Map),
    overview: json['overview'] as String?,
  );
}
