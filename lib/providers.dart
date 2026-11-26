import 'package:flutter/material.dart';

import 'data/media.dart';
import 'data/sports.dart';
import 'data/stremio.dart';
import 'data/tmdb.dart';
import 'host.dart';
import 'i18n.dart';
import 'settings.dart';

/// Stremio's page for a title, at the episode when there is one; with
/// [autoPlay], Stremio plays the stream it played there before, if any.
String stremioUri(
  MediaType type,
  String id,
  String? videoId, {
  bool autoPlay = false,
}) =>
    'stremio:///detail/${type == MediaType.series ? 'series' : 'movie'}'
    '/${Uri.encodeComponent(id)}'
    '${videoId == null ? '' : '/${Uri.encodeComponent(videoId)}'}'
    '${autoPlay ? '?autoPlay=true' : ''}';

/// The video Stremio plays for [item] (IMDb id [imdbId]) at once: a film's
/// own id; for a series the episode it is at ([item]'s, else [lastVideo]'s,
/// the one in progress in the account), else the first.
String playVideoId(
  MediaItem item,
  String imdbId,
  String? Function(String imdbId)? lastVideo,
) => item.type == MediaType.series
    ? item.videoId ?? lastVideo?.call(imdbId) ?? '$imdbId:1:1'
    : item.videoId ?? imdbId;

/// What YouTube apps open a video by.
String youtubeUri(String videoId) => 'vnd.youtube://$videoId';

/// The same video as a web link, for an app that takes only those.
String youtubeWebUri(String videoId) =>
    'https://www.youtube.com/watch?v=$videoId';

/// What an app must open to be offered as the movies and series provider, and
/// as the YouTube one.
const kStremioProbe = 'stremio:///detail/movie/tt0000001';
const kYoutubeProbe = 'vnd.youtube:dQw4w9WgXcQ';

/// The Stremio account is asked for only when a provider of titles is an app
/// that opens Stremio's links.
bool showStremioAccount({
  required String movieProvider,
  required String seriesProvider,
  required Iterable<String> stremioApps,
}) => [movieProvider, seriesProvider].any(stremioApps.contains);

/// The package Settings opens this kind of item in.
String providerFor(MediaItem item, Settings s) => switch (item.type) {
  MediaType.movie => s.movieProvider,
  MediaType.series => s.seriesProvider,
  MediaType.video => s.youtubeProvider,
  // Never asked: openItem opens a game by its add-on item, an input by its id.
  MediaType.game || MediaType.input => '',
};

/// The installed app whose label names the streaming [service] (a TMDB
/// provider name): the same name first, else one name inside the other (of 4
/// letters or more), compared without case, spaces or punctuation, with "+"
/// read as "plus" and "Amazon" left out. Null when none does.
String? suggestedApp(String service, Map<String, InstalledApp> apps) {
  String plain(String s) => s
      .toLowerCase()
      .replaceAll('+', 'plus')
      .replaceAll('amazon', '')
      .replaceAll(RegExp('[^a-z0-9]'), '');
  final name = plain(service);
  if (name.isEmpty) return null;
  final labels = [for (final a in apps.values) (a.package, plain(a.label))];
  bool inside(String label) {
    final (short, long) = label.length < name.length
        ? (label, name)
        : (name, label);
    return short.length >= 4 && long.contains(short);
  }

  return labels.where((l) => l.$2 == name).firstOrNull?.$1 ??
      labels.where((l) => inside(l.$2)).firstOrNull?.$1;
}

/// The packages of the mapped services among [providers], with each
/// service's name, in [providers] order.
Iterable<(String, String)> _mapped(
  List<WatchProvider> providers,
  Settings s,
) sync* {
  for (final w in providers) {
    final app = s.serviceApps['${w.id}'] ?? '';
    if (app.isNotEmpty) yield (app, w.name);
  }
}

/// The service a title opens in, for the highlight's button: in
/// streaming-apps mode, the first of [providers] mapped to an app that is
/// [installed] (when known), as [openItem] tries them; null otherwise.
String? watchOn(
  MediaItem item,
  List<WatchProvider> providers,
  Settings s, [
  Iterable<String>? installed,
]) =>
    (item.type == MediaType.movie || item.type == MediaType.series) &&
        providerFor(item, s).isEmpty
    ? _mapped(
        providers,
        s,
      ).where((m) => installed?.contains(m.$1) ?? true).firstOrNull?.$2
    : null;

/// Opens [item] in its provider: at the item when the provider can be told
/// which one (a video by its id, a title in a Stremio app by its Stremio id),
/// else on the provider's own home. With no provider for titles, in the app
/// of the first mapped service that has it; with none for videos, in any app
/// that opens YouTube's links. False when nothing opened.
///
/// With [Settings.stremioAutoPlay], a title in [kStremioPackage] opens at its
/// video ([playVideoId]) and plays its first stream.
Future<bool> openItem(
  MediaItem item,
  Settings s,
  TmdbSource tmdb, {
  String? Function(String imdbId)? lastVideo,
}) async {
  if (item.type == MediaType.game) return openGame(item, s);
  if (item.type == MediaType.input) {
    return Host.openInput(
      item.id,
      noSignal: t('noSignal'),
    ).catchError((_) => false);
  }
  final p = providerFor(item, s);
  if (item.type == MediaType.video) {
    final app = p.isEmpty ? null : p;
    return await Host.open(youtubeUri(item.id), package: app) ||
        await Host.open(youtubeWebUri(item.id), package: app) ||
        app != null && await Host.launch(app);
  }
  if (p.isEmpty) {
    // shortcut: TMDB gives no app deep links, so the app opens on its own
    // home; add a service's link here if one is ever documented.
    for (final (app, _) in _mapped(await tmdb.providersFor(item), s)) {
      if (await Host.launch(app)) return true;
    }
    return false;
  }
  final imdbId = item.imdbId ?? await tmdb.imdbIdFor(item);
  if (imdbId == null) return Host.launch(p);
  if (s.stremioAutoPlay && p == kStremioPackage) {
    final uri = stremioUri(
      item.type,
      imdbId,
      playVideoId(item, imdbId, lastVideo),
      autoPlay: true,
    );
    return await Host.openStremioAndPlay(uri, p) || await Host.launch(p);
  }
  return await Host.open(
        stremioUri(item.type, imdbId, item.videoId),
        package: p,
      ) ||
      await Host.launch(p);
}

/// [openItem], and a note on the screen of [context] when nothing opened.
void openItemOrSay(
  BuildContext context,
  MediaItem item,
  Settings s,
  TmdbSource tmdb, {
  String? Function(String imdbId)? lastVideo,
}) => openItem(item, s, tmdb, lastVideo: lastVideo).then((opened) {
  if (opened || !context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(
        t(item.type == MediaType.input ? 'inputOpenFailed' : 'openFailed'),
      ),
    ),
  );
}).ignore();

/// Stremio's page for the first of [items] whose name, or else description,
/// names both teams of [game] ([namesGame]); null when none does. A channel
/// that does not name them is never guessed.
String? stremioGameUri(Game game, List<CatalogItem> items) {
  for (final i in items) {
    if (namesGame(i.name, game) || namesGame(i.description, game)) {
      return 'stremio:///detail/${Uri.encodeComponent(i.type)}'
          '/${Uri.encodeComponent(i.id)}';
    }
  }
  return null;
}

/// Opens [item]'s game at its item in the Stremio account's sports add-on,
/// when one names both teams, in the Stremio app chosen for movies (else
/// series). False when nothing opened, or without an account or such an app.
Future<bool> openGame(
  MediaItem item,
  Settings s, {
  SportsCatalogs? catalogs,
}) async {
  final game = item.game;
  final key = s.stremioAuthKey;
  final app = s.movieProvider.isNotEmpty ? s.movieProvider : s.seriesProvider;
  if (game != null && key.isNotEmpty && app.isNotEmpty) {
    try {
      // The cache fills even when this stops waiting.
      final items = await (catalogs ?? sportsCatalogs)
          .items(key)
          .timeout(const Duration(seconds: 6));
      final uri = stremioGameUri(game, items);
      if (uri != null &&
          await (s.stremioAutoPlay && app == kStremioPackage
              ? Host.openStremioAndPlay(uri, app)
              : Host.open(uri, package: app))) {
        return true;
      }
    } catch (e) {
      debugPrint('stremio sports catalogs: $e');
    }
  }
  return false;
}

/// The YouTube key of the trailer of a film or series; null when TMDB has none,
/// or has no key to be asked with. A title from Stremio carries an IMDb id for
/// its id, so TMDB's is looked up first. A failed call throws a [TmdbError].
Future<String?> trailerKeyFor(MediaItem item, TmdbSource tmdb) async {
  if (tmdb.settings.tmdbKey.isEmpty) return null;
  final client = tmdb.client;
  final known = await client.known(item);
  return known == null ? null : client.trailer(known);
}

/// Opens the YouTube video [key] in the YouTube provider, else in any app
/// that opens YouTube's links; false when nothing opened.
Future<bool> openTrailerKey(String key, Settings s) async {
  final app = s.youtubeProvider.isEmpty ? null : s.youtubeProvider;
  return await Host.open(youtubeUri(key), package: app) ||
      await Host.open(youtubeWebUri(key), package: app);
}
