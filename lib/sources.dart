import 'package:flutter/foundation.dart';

import 'data/sports.dart';
import 'data/stremio.dart';
import 'data/tmdb.dart';
import 'data/weather.dart';
import 'data/youtube.dart';
import 'data/youtube_tv.dart';

/// The content services, started and stopped together with the app.
class Sources {
  final WeatherSource weather;
  final TmdbSource tmdb;
  final StremioSource stremio;
  final YoutubeSource youtube;
  final SportsSource sports;

  Sources({
    required this.weather,
    required this.tmdb,
    required this.stremio,
    required this.youtube,
    required this.sports,
  }) {
    stremio.addListener(_syncSeeds);
  }

  /// Adding a YouTube login; it shares [youtube]'s client, so a token is
  /// asked once.
  late final youtubeSignIn = YoutubeSignIn(youtube.settings, youtube.client);

  /// What Stremio has in progress is where TMDB's recommendations start from.
  /// When that changes, only the recommendations are redone.
  void _syncSeeds() {
    final seeds = stremio.seeds;
    if (listEquals(seeds, tmdb.seeds)) return;
    tmdb.seeds = seeds;
    // ponytail: a start with a cached row redoes the recommendations once,
    // whatever the TMDB cache says (it does not record the seeds it was made
    // from); keep the seeds in tmdb.json to skip that.
    tmdb.refreshRecommended().ignore();
  }

  Future<void> loadCache() => Future.wait([
    weather.loadCache(),
    tmdb.loadCache(),
    stremio.loadCache(),
    youtube.loadCache(),
    sports.loadCache(),
  ]);

  void start() {
    weather.start();
    tmdb.start();
    stremio.start();
    youtube.start();
    sports.start();
  }

  void stop() {
    weather.stop();
    tmdb.stop();
    stremio.stop();
    youtube.stop();
    sports.stop();
    // A sign-in never waits for the phone in the background.
    youtubeSignIn.stop();
  }
}
