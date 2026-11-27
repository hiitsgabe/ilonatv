import 'dart:async';
import 'dart:io';

import 'package:ilonatv_protocol/ilonatv_protocol.dart' show kCompanionPort;
import 'package:flutter/foundation.dart' show kProfileMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'app.dart';
import 'companion/api.dart';
import 'companion/pairing.dart';
import 'companion/server.dart';
import 'companion/state.dart';
import 'data/media.dart';
import 'data/sports.dart';
import 'data/stremio.dart';
import 'data/tmdb.dart';
import 'data/weather.dart';
import 'data/youtube.dart';
import 'data/youtube_tv.dart';
import 'device.dart';
import 'disk_images.dart';
import 'host.dart';
import 'i18n.dart';
import 'providers.dart' show openGame, openItem, youtubeUri, youtubeWebUri;
import 'settings.dart';
import 'settings_import.dart';
import 'snapshot.dart';
import 'sources.dart';
import 'store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Profile builds log the frames over budget with their build and raster
  // times (`adb logcat -s flutter`): what the TV does with the home.
  if (kProfileMode) {
    SchedulerBinding.instance.addTimingsCallback((timings) {
      for (final t in timings) {
        if (t.totalSpan.inMilliseconds > 17) {
          debugPrint(
            'frame ${t.totalSpan.inMilliseconds} ms: build '
            '${t.buildDuration.inMilliseconds}, raster '
            '${t.rasterDuration.inMilliseconds}',
          );
        }
      }
    });
  }
  // The engine's default GPU budget is the viewport × 12 frames (95 MB at
  // 1080p), so scratch textures pile up. 32 MB holds what is on screen with
  // room for the raster cache (the dock's glass, a row's cards): at 16 MB the
  // cache was purged between frames and the GPU drew them again each one.
  // The call fails where there is no engine (tests): nothing to do then.
  SystemChannels.skia
      .invokeMethod<void>('Skia.setResourceCacheMaxBytes', 32 << 20)
      .ignore();
  // Posters, thumbs and icons, by the device's RAM; the backdrops keep their
  // own bytes.
  await Device.tune();
  final filesDir = await Host.filesDir();
  // Before the load, so what came over adb goes through its migrations.
  await importSettings(File('$filesDir/import/settings.json'));
  final s = await Settings.load();
  I18n.language = s.language;
  final store = Store(Directory(filesDir));
  DiskImages.dir = Directory('$filesDir/cache/img');
  // The app list of the last run, so the dock is in the first frame.
  final cachedApps = await store.read('apps');
  final sources = Sources(
    weather: WeatherSource(s, store),
    tmdb: TmdbSource(s, store),
    stremio: StremioSource(s, store),
    youtube: YoutubeSource(s, store, YoutubeTvClient(store: store)),
    sports: SportsSource(s, store),
  );
  // The voice assistant's YouTube and games: what the overlay shows and what
  // OK opens. A game or a title opens here, the way the home opens it.
  Host.onAssistantSearch = (type, query, what) async {
    if (type == 'games') {
      final now = DateTime.now();
      return [
        for (final (i, today) in await sources.sports.assistantGames(
          query == '*' ? '' : query,
          what,
        ))
          {
            'title': i.title,
            'sub': gameStatus(i.game!, now),
            'id': i.id,
            'today': today,
            'homeLogo': i.game!.home.logo,
            'awayLogo': i.game!.away.logo,
            'homeAbbr': i.game!.home.abbr,
            'awayAbbr': i.game!.away.abbr,
          },
      ];
    }
    if (type != 'youtube') return const [];
    final videos = await sources.youtube.assistantSearch(query, what);
    return [
      for (final v in videos.take(12))
        {
          'title': v.title,
          'sub': v.subtitle ?? '',
          'poster': v.posterUrl ?? v.backdropUrl,
          'uri': youtubeUri(v.id),
          'webUri': youtubeWebUri(v.id),
          'package': s.youtubeProvider.isEmpty ? null : s.youtubeProvider,
        },
    ];
  };
  Host.onAssistantOpen = (type, id) async {
    if (type == 'movie' || type == 'series') {
      return openItem(
        MediaItem(
          type: type == 'movie' ? MediaType.movie : MediaType.series,
          id: id,
          title: '',
        ),
        s,
        sources.tmdb,
        lastVideo: sources.stremio.lastVideo,
      );
    }
    if (type != 'games') return false;
    final item = sources.sports.games.where((i) => i.id == id).firstOrNull;
    return item != null && await openGame(item, s);
  };
  // The cached forecast is read before the first frame, so it is on screen
  // from the start.
  await sources.loadCache();
  final pairing = Pairing(s);
  runApp(
    IlonaTvApp(s, sources, store, pairing: pairing, cachedApps: cachedApps),
  );
  WidgetsBinding.instance.addObserver(SnapshotObserver(homeBoundaryKey, s));
  sources.start();
  // Another app on the port, or no network, leaves Ilona TV without its
  // Companion, not without its home.
  final api = IlonaTvApi(s, sources);
  unawaited(
    CompanionServer(pairing, api, outside: api.outside)
        .start()
        .then((_) => Host.advertise(kCompanionPort, 'Ilona TV'))
        .catchError((Object e) => debugPrint('companion server: $e')),
  );
  DiskImages.prune().ignore();
  // The sources run only while the app is in the foreground; a wake from
  // standby resumes it, and start() refreshes what went stale meanwhile. The
  // binding holds the listener for good, so it needs no variable and no
  // dispose.
  AppLifecycleListener(
    onResume: () {
      companionState.setInFront(true);
      sources.start();
    },
    onPause: () {
      companionState.setInFront(false);
      sources.stop();
    },
  );
}
