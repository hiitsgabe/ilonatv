import 'dart:async';

import 'package:flutter/foundation.dart';

import '../i18n.dart';
import '../net.dart';
import '../settings.dart';
import '../store.dart';
import 'media.dart';

const _api = 'https://api.strem.io/api';

/// Stremio's phone link: the TV asks for a code, a phone approves it, and the
/// TV reads the account's `authKey` back.
const _link = 'https://link.stremio.com/api/v2';

/// How old the cached row may be, and how often the open app asks again.
const _every = Duration(minutes: 15);

const _cache = 'stremio';

/// How often the TV asks if a phone approved its code; after 100 asks (5
/// minutes) the code is replaced, and after 300 (15 minutes) the wait ends.
const _linkEvery = Duration(seconds: 3);
const _linkRenew = 100;
const _linkGiveUp = 300;

/// Stremio's own answer to a call it refused: `{"error": {"message", "code"}}`.
class StremioError implements Exception {
  final String message;
  final int code;
  const StremioError(this.message, this.code);

  @override
  String toString() => 'StremioError($code, $message)';
}

/// What links the TV to an account from a phone: [code] is what the phone is
/// told, [link] the page it opens, and [qrcodeUrl] the image of that page's QR.
class LinkCode {
  final String code;
  final String link;
  final String qrcodeUrl;
  const LinkCode(this.code, this.link, this.qrcodeUrl);
}

/// The calls to Stremio's API that the home needs. A call that Stremio answers
/// with an error throws a [StremioError]; any other failure (the network, a
/// status, a body that is not Stremio's) is what [Post] or the parsing threw.
class StremioClient {
  final Post _post;
  final Fetch _get;

  StremioClient({this._post = postJson, this._get = getJson});

  /// [json] as it is, or the [StremioError] it holds.
  Map<String, dynamic> _checked(Map<String, dynamic> json) {
    if (json['error'] case {'message': String message, 'code': num code}) {
      throw StremioError(message, code.toInt());
    }
    return json;
  }

  Future<Map<String, dynamic>> _call(
    String method,
    Map<String, dynamic> body,
  ) async => _checked(await _post(Uri.parse('$_api/$method'), body));

  /// A new code to link this TV to an account from a phone.
  Future<LinkCode> createLinkCode() async {
    final json = _checked(await _get(Uri.parse('$_link/create?type=Create')));
    final result = json['result'] as Map;
    return LinkCode(
      result['code'] as String,
      result['link'] as String,
      result['qrcode'] as String,
    );
  }

  /// The `authKey` of the account whose phone approved [code]; null until one
  /// has. Stremio answers an error before that, and for a code that expired,
  /// so any error is null here; the network and a body that is not Stremio's
  /// are thrown.
  Future<String?> readLinkCode(String code) async {
    final uri = Uri.parse('$_link/read')
        .replace(queryParameters: {'type': 'Read', 'code': code});
    final json = await _get(uri);
    if (json['error'] != null) return null;
    return (json['result'] as Map)['authKey'] as String;
  }

  /// The email of the account [authKey] belongs to; empty if Stremio sends none.
  Future<String> userEmail(String authKey) async {
    final json = await _call('getUser', {
      'type': 'GetUser',
      'authKey': authKey,
    });
    return (json['result'] as Map)['email'] as String? ?? '';
  }

  /// The catalogs of the account's add-ons that are not of films or series,
  /// nor need an `extra` to answer:
  /// `<base>/catalog/<type>/<id>.json`, the base being the add-on's
  /// `transportUrl` without its `/manifest.json`. An add-on or catalog that
  /// cannot be read is left out.
  Future<List<Uri>> addons(String authKey) async {
    final json = await _call('addonCollectionGet', {
      'type': 'AddonCollectionGet',
      'authKey': authKey,
      'update': true,
    });
    return [
      for (final addon in (json['result'] as Map)['addons'] as List)
        if (addon case {
          'transportUrl': final String url,
          'manifest': {'catalogs': final List catalogs},
        })
          for (final c in catalogs)
            if (c case {'type': final String type, 'id': final String id}
                when type != 'movie' && type != 'series' && !_needsExtra(c))
              Uri.parse(
                '${url.replaceFirst(RegExp(r'/manifest\.json$'), '')}'
                '/catalog/${Uri.encodeComponent(type)}'
                '/${Uri.encodeComponent(id)}.json',
              ),
    ];
  }

  /// A catalog that answers only with an `extra` (a search, a genre): both
  /// ways a manifest says so.
  static bool _needsExtra(Map c) =>
      (c['extraRequired'] is List && (c['extraRequired'] as List).isNotEmpty) ||
      (c['extra'] is List &&
          (c['extra'] as List).any((e) => e is Map && e['isRequired'] == true));

  /// The items of the catalog at [url] (see [addons]); one that cannot be read
  /// is left out.
  Future<List<CatalogItem>> catalog(Uri url) async => [
    for (final meta in (await _get(url))['metas'] as List? ?? const [])
      if (meta case {'id': final String id, 'type': final String type})
        CatalogItem(
          id,
          type,
          meta['name'] as String? ?? '',
          meta['description'] as String? ?? '',
        ),
  ];

  /// The whole library of the account [authKey] belongs to.
  Future<List<LibraryItem>> library(String authKey) async {
    // ponytail: all of it, every time. A library of thousands of titles is a
    // big answer every 15 minutes; ask `datastoreMeta` first and fetch only
    // the changed `ids` if that hurts on the Fire TV.
    return parseLibrary(
      await _call('datastoreGet', {
        'authKey': authKey,
        'collection': 'libraryItem',
        'ids': [],
        'all': true,
      }),
    );
  }
}

/// An item of an add-on's catalog: Stremio opens it as
/// `stremio:///detail/<type>/<id>`.
class CatalogItem {
  final String id;
  final String type;
  final String name;
  final String description;
  const CatalogItem(this.id, this.type, this.name, this.description);
}

/// The items of the account's catalogs that are not of films or series (where
/// a sports add-on lists its games and channels). Asked for again after 10
/// minutes, or after 1 when a catalog failed or took over [_wait] (it is left
/// out meanwhile), or for another account. Two asks while one is out share it.
class SportsCatalogs {
  final StremioClient _client;
  final DateTime Function() _now;
  final Duration _wait;
  String? _key;
  DateTime _until = DateTime.utc(0);
  List<CatalogItem> _items = const [];
  (String, Future<List<CatalogItem>>)? _pending;

  SportsCatalogs({
    StremioClient? client,
    this._now = DateTime.now,
    this._wait = const Duration(seconds: 4),
  }) : _client = client ?? StremioClient();

  Future<List<CatalogItem>> items(String authKey) {
    if (authKey == _key && _now().isBefore(_until)) return Future.value(_items);
    if (_pending case (final key, final out) when key == authKey) return out;
    late final Future<List<CatalogItem>> out;
    out = _fetch(authKey).whenComplete(() {
      if (identical(_pending?.$2, out)) _pending = null;
    });
    _pending = (authKey, out);
    return out;
  }

  Future<List<CatalogItem>> _fetch(String authKey) async {
    final urls = await _client.addons(authKey);
    var whole = true;
    final lists = await Future.wait([
      for (final url in urls)
        _client.catalog(url).timeout(_wait).catchError((Object e) {
          debugPrint('stremio catalog $url: $e');
          whole = false;
          return <CatalogItem>[];
        }),
    ]);
    _key = authKey;
    _until = _now().add(Duration(minutes: whole ? 10 : 1));
    return _items = [for (final l in lists) ...l];
  }
}

/// The one [SportsCatalogs] the app asks.
final sportsCatalogs = SportsCatalogs();

/// A text that is there and not empty, else null.
String? _text(Object? value) =>
    value is String && value.isNotEmpty ? value : null;

/// One entry of the library, with the parts the home reads.
class LibraryItem {
  /// Stremio's `_id`: an IMDb id (`tt...`) for most titles.
  final String id;
  final String name;

  /// `movie`, `series` or something else Stremio keeps (`other`, `tv`...).
  final String type;
  final String? poster;

  /// Taken out of the library. Still shown while [temp] (see
  /// [continueWatching]).
  final bool removed;
  final bool temp;

  /// When the entry last changed, as watching does: the row is in this order.
  final DateTime mtime;

  /// Where the person stopped, in milliseconds.
  final int timeOffset;

  /// The video the person stopped at: `<id>:<season>:<episode>` for a series.
  final String? videoId;

  const LibraryItem({
    required this.id,
    required this.name,
    required this.type,
    this.poster,
    required this.removed,
    required this.temp,
    required this.mtime,
    required this.timeOffset,
    this.videoId,
  });

  /// Throws for an entry with no text `_id`, `name` or `type`, or no readable
  /// `_mtime`. The rest has a default: an entry with no `state` has not been
  /// watched.
  factory LibraryItem.fromJson(Map json) {
    final state = json['state'] as Map? ?? const {};
    return LibraryItem(
      id: json['_id'] as String,
      name: json['name'] as String,
      type: json['type'] as String,
      poster: _text(json['poster']),
      removed: json['removed'] as bool? ?? false,
      temp: json['temp'] as bool? ?? false,
      mtime: DateTime.parse(json['_mtime'] as String),
      timeOffset: (state['timeOffset'] as num? ?? 0).toInt(),
      videoId: _text(state['video_id']),
    );
  }
}

/// The `result` of a `datastoreGet` of the library. An entry that cannot be
/// read is left out, not the whole library.
List<LibraryItem> parseLibrary(Map<String, dynamic> json) => [
  for (final entry in json['result'] as List) ?_readable(entry),
];

LibraryItem? _readable(Object? entry) {
  try {
    return LibraryItem.fromJson(entry as Map);
  } catch (_) {
    return null;
  }
}

/// "S2 · E5", or "T2 · E5" in Portuguese.
String seasonEpisode(int season, int episode) =>
    '${I18n.language == 'pt' ? 'T' : 'S'}$season · E$episode';

/// "S2 · E5" for a series stopped at the video `<id>:<season>:<episode>`;
/// null for anything else. The id is cut off, not split on the colons: an
/// add-on's ids can have one (`kitsu:7442`).
String? _episode(LibraryItem item) {
  final videoId = item.videoId;
  final prefix = '${item.id}:';
  if (item.type != 'series' || videoId == null || !videoId.startsWith(prefix)) {
    return null;
  }
  if (videoId.substring(prefix.length).split(':').map(int.tryParse).toList()
      case [final season?, final episode?]) {
    return seasonEpisode(season, episode);
  }
  return null;
}

/// The "Continue watching" row: the films and series with something watched
/// and not finished, the most recently watched first, 20 at most. An item
/// taken out of the library stays while it is `temp` (watched without being
/// added to it).
List<MediaItem> continueWatching(List<LibraryItem> items) {
  final inProgress = [
    for (final i in items)
      if ((i.type == 'movie' || i.type == 'series') &&
          (!i.removed || i.temp) &&
          i.timeOffset > 0)
        i,
  ]..sort((a, b) => b.mtime.compareTo(a.mtime));
  return [
    for (final i in inProgress.take(20))
      MediaItem(
        type: i.type == 'series' ? MediaType.series : MediaType.movie,
        id: i.id,
        title: i.name,
        posterUrl: i.poster,
        // Stremio's own background for an IMDb title, by its id: no call. A
        // title without one answers 404, and the backdrop keeps its gradient.
        backdropUrl: i.id.startsWith('tt')
            ? 'https://images.metahub.space/background/medium/${i.id}/img'
            : null,
        imdbId: i.id,
        videoId: i.videoId,
        subtitle: _episode(i),
      ),
  ];
}

// The source has a field of this name, which hides the function in the class.
const _toRow = continueWatching;

/// The Stremio account's "Continue watching" row. The last answer is cached on
/// disk, so the home opens with it; the open app asks again every 15 minutes.
class StremioSource extends ChangeNotifier {
  final Settings settings;
  final Store store;
  final StremioClient _client;
  Timer? _timer;

  /// What is in progress in the library, the most recent first; empty without
  /// an account.
  List<MediaItem> continueWatching = [];

  /// The episode of the series [imdbId] that is in progress in the account;
  /// null when it is not in [continueWatching].
  String? lastVideo(String imdbId) => continueWatching
      .where((i) => i.type == MediaType.series && i.imdbId == imdbId)
      .firstOrNull
      ?.videoId;

  /// What is wrong with the row: Stremio's own message, or `network` for any
  /// other failure; null when the last refresh went well or none has run. The
  /// row is whatever the cache and the last good refresh gave, whatever the
  /// error.
  String? error;

  /// The code a phone is asked to approve, while the TV waits for one; null
  /// otherwise.
  LinkCode? linkCode;

  /// The last wait ended with no answer. [startLink] clears it.
  bool linkExpired = false;

  Timer? _link;

  /// Set by [startLink] and cleared by [cancelLink]: tells a code that arrives
  /// late that nobody waits for it any more.
  bool _linkWanted = false;
  int _polls = 0;
  bool _polling = false;

  StremioSource(this.settings, this.store, {StremioClient? client})
    : _client = client ?? StremioClient();

  /// Shows what the last run cached, of any age: the first [refresh] replaces
  /// it when it is due. A cache this version cannot read is skipped as a
  /// whole.
  Future<void> loadCache() async {
    try {
      final cached = await store.read(_cache);
      if (cached == null) return;
      continueWatching = [
        for (final json in cached['items'] as List) MediaItem.fromJson(json),
      ];
      notifyListeners();
    } catch (_) {}
  }

  /// Asks Stremio for the library, unless there is no account (the row is then
  /// empty and nothing is asked) or the cache holds a row under 15 minutes
  /// old; [force] asks anyway. The row is replaced only when the call went
  /// well. A failure of any kind leaves it as it was and sets [error]; the
  /// next refresh tries again.
  Future<void> refresh({bool force = false}) async {
    final key = settings.stremioAuthKey;
    if (key.isEmpty) {
      if (continueWatching.isNotEmpty) {
        continueWatching = [];
        notifyListeners();
      }
      return;
    }
    List<MediaItem>? row;
    var failure = 'network'; // unless Stremio itself says why
    try {
      if (!force && await store.freshOrNull(_cache, _every) != null) return;
      final library = await _client.library(key);
      row = _toRow(library);
      debugPrint(
        'stremio library: ${library.length} items, ${row.length} in progress',
      );
    } on StremioError catch (e) {
      failure = e.message;
      debugPrint('stremio library: $failure');
    } catch (e) {
      debugPrint('stremio library failed: $e');
      // ponytail: no retry. A failed refresh waits for the next tick or
      // resume; retry once after a few seconds if a TV that boots before its
      // Wi-Fi leaves the row stale for too long.
    }
    // Logged out, or in as someone else, while the call was out: the answer
    // (or the failure) is not this account's.
    if (settings.stremioAuthKey != key) return;
    if (row == null) {
      _setError(failure);
      return;
    }
    continueWatching = row;
    error = null;
    notifyListeners();
    // Last, so a cache that will not write (a full disk) cannot undo a good
    // fetch.
    try {
      await store.write(_cache, {
        'items': [for (final i in row) i.toJson()],
      });
    } catch (_) {}
  }

  void _setError(String e) {
    if (error == e) return;
    error = e;
    notifyListeners();
  }

  /// Refreshes at once, if due, and then every 15 minutes. Safe to call again.
  void start() {
    refresh();
    // The tick forces: it comes just under 15 minutes after the cache was
    // written, which would still count as fresh.
    _timer ??= Timer.periodic(_every, (_) => refresh(force: true));
  }

  /// Ends the wait for a phone too. Safe without a [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
    cancelLink();
  }

  /// Asks Stremio for a code, shows it in [linkCode] and waits for a phone to
  /// approve it, asking every 3 seconds. A phone that does gives the account:
  /// kept in Settings, its row fetched. A code nobody approves is replaced
  /// after 5 minutes, and the wait ends after 15, with [linkExpired]. Failing
  /// to get the first code is thrown as it is, and there is no wait then. A
  /// [stop] or [cancelLink] while that code is out drops it.
  Future<void> startLink() async {
    linkExpired = false;
    _linkWanted = true;
    final code = await _client.createLinkCode();
    if (!_linkWanted) return; // stopped or cancelled while the code was out
    linkCode = code;
    _polls = 0;
    notifyListeners();
    _link ??= Timer.periodic(_linkEvery, (_) => _poll());
  }

  /// One tick of the wait. An ask that fails is asked again on the next tick;
  /// a tick that finds the last ask still out does nothing.
  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final code = linkCode;
      if (code == null) return;
      _polls++;
      final String? key;
      try {
        key = await _client.readLinkCode(code.code);
      } catch (e) {
        debugPrint('stremio link read: $e'); // a new shape of answer shows here
        return;
      }
      // Cancelled, or replaced, while the call was out.
      if (linkCode != code) return;
      if (key != null) {
        cancelLink();
        // The key first: the pane shows the account, not the way in, while the
        // email is asked.
        settings
          ..stremioAuthKey = key
          ..stremioEmail = await _emailOrEmpty(key);
        await settings.save();
        await refresh(force: true);
      } else if (_polls >= _linkGiveUp) {
        cancelLink();
        linkExpired = true;
        notifyListeners();
      } else if (_polls % _linkRenew == 0) {
        try {
          final next = await _client.createLinkCode();
          // Unless it was cancelled, or started again, meanwhile.
          if (linkCode == code) {
            linkCode = next;
            notifyListeners();
          }
        } catch (_) {} // the code on screen stays, and the wait with it
      }
    } finally {
      _polling = false;
    }
  }

  /// The account's email, or none: the account is kept either way.
  Future<String> _emailOrEmpty(String key) async {
    try {
      return await _client.userEmail(key);
    } catch (_) {
      return '';
    }
  }

  /// Ends the wait for a phone: no more asks, and no [linkCode]. Safe without
  /// one.
  void cancelLink() {
    _linkWanted = false;
    _link?.cancel();
    _link = null;
    if (linkCode != null) {
      linkCode = null;
      notifyListeners();
    }
  }

  /// Forgets the account: its key, its email, its cache and its row.
  Future<void> logout() async {
    settings
      ..stremioAuthKey = ''
      ..stremioEmail = '';
    await settings.save();
    await store.delete(_cache);
    continueWatching = [];
    error = null;
    notifyListeners();
  }

  /// IMDb ids of the first five titles in progress that have one: where TMDB's
  /// recommendations start from.
  List<String> get seeds =>
      [for (final i in continueWatching) ?i.imdbId]
          .where((id) => id.startsWith('tt'))
          .take(5)
          .toList();
}
