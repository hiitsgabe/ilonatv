import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../i18n.dart';
import '../locale.dart';
import '../net.dart';
import '../settings.dart';
import '../store.dart';
import 'media.dart';

/// YouTube as the "YouTube on TV" app sees it, the way SmartTube talks to it:
/// the TV client's credentials are read off youtube.com/tv at run time (never
/// kept in the repository), a phone approves a device code, and the
/// InnerTube calls carry the TV's User-Agent and client version.
const kTvUserAgent =
    'Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) '
    'Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles '
    'Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, '
    'Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0';
const kTvClientVersion = '7.20260901.15.00';

const _site = 'https://www.youtube.com';
const _deviceCodeUrl = '$_site/o/oauth2/device/code';
const _tokenUrl = '$_site/o/oauth2/token';
const _scope =
    'http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content';

/// Where the credentials scraped from youtube.com/tv are kept, with when.
const _credentialsCache = 'youtube_client';

/// A pair scraped this recently is not scraped again, refused or not: Google
/// would get the same one.
const _rescrapeAfter = Duration(minutes: 10);

/// The page's base script, in the forms SmartTube knows (the first that
/// matches wins), and the client id and secret inside it. Only the first
/// occurrence of the pair works: later ones are refused.
final _baseScript = [
  RegExp(r'id="base-js" src="(.*?)"'),
  RegExp(r"\.src = '(.*?m=base)'"),
  RegExp(r"\.src = '(.*?)'; .\.id = 'base-js'"),
];

/// The visitor id the /tv page hands out, which browse calls carry.
final _visitorIn = RegExp(r'"visitorData":"(.*?)"');
final _clientPair = RegExp(
  r'clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"([-\w]+)"',
);

/// How an OAuth call ended, other than the network or a body that is not
/// OAuth's.
enum YtAuthError implements Exception {
  /// Asked too often: wait 5 s more between asks.
  slowDown,

  /// The code ran out before a phone approved it.
  expired,

  /// The phone said no, or Google refused the code for another reason.
  denied,

  /// The refresh token no longer works: the account must sign in again.
  revoked,
}

/// Google refused the client id or secret (they were rotated): scrape again.
class _ClientRefused implements Exception {
  @override
  String toString() => 'YouTube refused the TV client credentials';
}

class YtCredentials {
  final String id, secret;
  const YtCredentials(this.id, this.secret);
}

/// What the phone is told ([userCode], at [verificationUrl]) and what the TV
/// asks with ([deviceCode]), every [interval] seconds for [expiresIn].
class YtDeviceCode {
  final String deviceCode, userCode, verificationUrl;
  final int interval, expiresIn;
  const YtDeviceCode({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUrl,
    required this.interval,
    required this.expiresIn,
  });
}

/// One YouTube profile: the Google account itself, or one of its brand
/// accounts (with a [pageId]). Profiles of one sign-in share [refreshToken].
/// The home shows the [enabled] ones.
class YtAccount {
  final String refreshToken, name;
  final String? avatarUrl, pageId;
  final bool enabled;
  const YtAccount({
    required this.refreshToken,
    required this.name,
    this.avatarUrl,
    this.pageId,
    this.enabled = true,
  });

  /// What tells two profiles apart: the brand's page, else the name.
  String get key => pageId ?? name;

  YtAccount copyWith({bool? enabled}) => YtAccount(
    refreshToken: refreshToken,
    name: name,
    avatarUrl: avatarUrl,
    pageId: pageId,
    enabled: enabled ?? this.enabled,
  );

  Map<String, dynamic> toJson() => {
    'refreshToken': refreshToken,
    'name': name,
    'avatarUrl': avatarUrl,
    'pageId': pageId,
    'enabled': enabled,
  };

  /// A missing `enabled` (saved before there was one) is true.
  factory YtAccount.fromJson(Map json) => YtAccount(
    refreshToken: json['refreshToken'] as String,
    name: json['name'] as String,
    avatarUrl: json['avatarUrl'] as String?,
    pageId: json['pageId'] as String?,
    enabled: json['enabled'] as bool? ?? true,
  );
}

/// The headers of an InnerTube call as the TV, signed in with [accessToken];
/// anonymous without one.
Map<String, String> tvHeaders(String? accessToken, {String? pageId}) => {
  'User-Agent': kTvUserAgent,
  'Referer': '$_site/tv',
  'Authorization': ?(accessToken == null ? null : 'Bearer $accessToken'),
  'X-Goog-Pageid': ?pageId,
};

/// The `context` of an InnerTube call as the TV, in the app's language and
/// the device's country.
Map<String, dynamic> tvContext({String? visitorData}) => {
  'client': {
    'clientName': 'TVHTML5',
    'clientVersion': kTvClientVersion,
    'clientScreen': 'WATCH',
    'userAgent': kTvUserAgent,
    'browserName': 'Cobalt',
    'browserVersion': '22.lts.3.306369-gold',
    'tvAppInfo': {
      'appQuality': 'TV_APP_QUALITY_FULL_ANIMATION',
      'zylonLeftNav': true,
    },
    'webpSupport': false,
    'animatedWebpSupport': true,
    'acceptLanguage': I18n.language,
    'acceptRegion': deviceCountry(),
    // A string, as SmartTube sends it.
    'utcOffsetMinutes': '${DateTime.now().timeZoneOffset.inMinutes}',
    'visitorData': ?visitorData,
  },
  'user': {'enableSafetyMode': false, 'lockedSafetyMode': false},
};

/// The calls to YouTube that sign in and read the accounts. The network and a
/// body that cannot be read are thrown as [Post] or the parsing threw them.
class YoutubeTvClient {
  final Post _post;
  final GetText _getText;
  final Store store;

  /// Access tokens in memory, by refresh token, with when to stop using them.
  final _tokens = <String, (String, DateTime)>{};

  /// The renewal under way, by refresh token: callers that ask meanwhile wait
  /// for it instead of starting another.
  final _renewing = <String, Future<String>>{};

  /// The scrape under way: callers that need one meanwhile wait for it.
  Future<YtCredentials>? _scraping;

  /// The visitor id of /tv, asked once per run; a failed ask is asked again.
  Future<String?>? _visitor;

  YoutubeTvClient({
    required this.store,
    this._post = postJson,
    this._getText = getText,
  });

  /// The TV client's id and secret: from [store], unless there are none there
  /// or [fresh]; then read off youtube.com/tv and kept. [fresh] keeps a pair
  /// scraped under 10 minutes ago. A page where they are not found is a
  /// [FormatException].
  Future<YtCredentials> credentials({bool fresh = false}) async {
    final cached = await store.read(_credentialsCache);
    if (cached case {'id': String id, 'secret': String secret}) {
      final at = DateTime.fromMillisecondsSinceEpoch(
        (cached['at'] as num? ?? 0).toInt(),
      );
      final age = DateTime.now().difference(at);
      if (!fresh || (!age.isNegative && age < _rescrapeAfter)) {
        return YtCredentials(id, secret);
      }
    }
    return _scraping ??= _scrape().whenComplete(() {
      _scraping = null;
    });
  }

  Future<YtCredentials> _scrape() async {
    const headers = {'User-Agent': kTvUserAgent};
    final page = await _getText(Uri.parse('$_site/tv'), headers: headers);
    if (_visitorIn.firstMatch(page)?.group(1) case final v?) {
      _visitor ??= Future.value(v);
    }
    final path = [for (final r in _baseScript) ?r.firstMatch(page)?.group(1)]
        .firstOrNull;
    if (path == null) throw const FormatException('no base script on /tv');
    final script = await _getText(
      Uri.parse(_site).resolve(path),
      headers: headers,
    );
    final pair = _clientPair.firstMatch(script);
    if (pair == null) throw const FormatException('no client id in base.js');
    final credentials = YtCredentials(pair.group(1)!, pair.group(2)!);
    try {
      await store.write(_credentialsCache, {
        'id': credentials.id,
        'secret': credentials.secret,
        'at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {} // a full disk: scraped again next time
    return credentials;
  }

  /// [call] with the credentials; once more with freshly scraped ones if
  /// Google refused them.
  Future<T> _withCredentials<T>(
    Future<T> Function(YtCredentials c) call,
  ) async {
    try {
      return await call(await credentials());
    } on _ClientRefused {
      return call(await credentials(fresh: true));
    }
  }

  /// An OAuth call. Its error answers come as JSON with a status or without
  /// one (a 200 while the phone has not approved yet, a 428 for the same
  /// thing): either way they are returned, except a refused client, which is
  /// [_ClientRefused].
  Future<Map<String, dynamic>> _oauth(
    String url,
    Map<String, dynamic> body,
  ) async {
    Map<String, dynamic> json;
    try {
      json = await _post(Uri.parse(url), body);
    } on HttpStatusException catch (e) {
      if (e.status >= 500) rethrow; // the network's trouble, not OAuth's answer
      if (e.status == 401) throw _ClientRefused();
      if (e.status == 428) return {'error': 'authorization_pending'};
      try {
        json = jsonDecode(e.body) as Map<String, dynamic>;
      } catch (_) {
        throw e; // not OAuth's answer
      }
    }
    if (json['error'] == 'invalid_client') throw _ClientRefused();
    return json;
  }

  /// A code for a phone to approve; [deviceId] is this install's.
  Future<YtDeviceCode> deviceCode(String deviceId) =>
      _withCredentials((c) async {
        final json = await _oauth(_deviceCodeUrl, {
          'client_id': c.id,
          'device_id': deviceId,
          'model_name': 'ytlr::',
          'scope': _scope,
        });
        final interval = (json['interval'] as num? ?? 0).toInt();
        return YtDeviceCode(
          deviceCode: json['device_code'] as String,
          userCode: json['user_code'] as String,
          verificationUrl: json['verification_url'] as String,
          interval: interval >= 1 ? interval : 5,
          expiresIn: (json['expires_in'] as num? ?? 1800).toInt(),
        );
      });

  /// The refresh token once a phone approved [code]; null while none has.
  /// Throws [YtAuthError.slowDown] (ask less often), [YtAuthError.expired], or
  /// [YtAuthError.denied] for a no or any other error.
  Future<String?> pollToken(YtDeviceCode code) => _withCredentials((c) async {
    final json = await _oauth(_tokenUrl, {
      'code': code.deviceCode,
      'client_id': c.id,
      'client_secret': c.secret,
      'grant_type': 'http://oauth.net/grant_type/device/1.0',
    });
    switch (json['error']) {
      case null:
        final refresh = json['refresh_token'] as String;
        try {
          _remember(refresh, json);
        } catch (_) {} // no access token with it: accessToken asks for one
        return refresh;
      case 'authorization_pending':
        return null;
      case 'slow_down':
        throw YtAuthError.slowDown;
      case 'expired_token':
        throw YtAuthError.expired;
      default:
        throw YtAuthError.denied;
    }
  });

  /// Keeps the access token of [json] until a minute before it runs out.
  String _remember(String refreshToken, Map<String, dynamic> json) {
    final token = json['access_token'] as String;
    final seconds = (json['expires_in'] as num? ?? 3600).toInt();
    _tokens[refreshToken] = (
      token,
      DateTime.now().add(Duration(seconds: seconds - 60)),
    );
    return token;
  }

  /// An access token for [refreshToken]: the one in memory while it has more
  /// than a minute left, else a new one, asked once however many callers wait
  /// for it. A revoked refresh token is [YtAuthError.revoked].
  Future<String> accessToken(String refreshToken) {
    final kept = _tokens[refreshToken];
    if (kept != null && DateTime.now().isBefore(kept.$2)) {
      return Future.value(kept.$1);
    }
    return _renewing[refreshToken] ??= _renew(refreshToken)
        // A block: returning the removed future would make this one wait for
        // itself.
        .whenComplete(() {
          _renewing.remove(refreshToken);
        });
  }

  Future<String> _renew(String refreshToken) => _withCredentials((c) async {
    final json = await _oauth(_tokenUrl, {
      'refresh_token': refreshToken,
      'client_id': c.id,
      'client_secret': c.secret,
      'grant_type': 'refresh_token',
    });
    switch (json['error']) {
      case null:
        return _remember(refreshToken, json);
      case 'invalid_grant':
        _tokens.remove(refreshToken);
        throw YtAuthError.revoked;
      case final error:
        throw FormatException('youtube token: $error');
    }
  });

  /// The profiles [refreshToken] signs in to: the Google account and its brand
  /// accounts. None readable is a [FormatException].
  Future<List<YtAccount>> accounts(String refreshToken) async {
    final json = await _post(
      Uri.parse('$_site/youtubei/v1/account/accounts_list?prettyPrint=false'),
      {
        'context': tvContext(),
        'accountReadMask': {
          'returnOwner': true,
          'returnBrandAccounts': true,
          'returnPersonaAccounts': false,
        },
      },
      headers: tvHeaders(await accessToken(refreshToken)),
    );
    final accounts = parseAccounts(json, refreshToken);
    if (accounts.isEmpty) throw const FormatException('no accounts');
    return accounts;
  }

  Future<String?> _visitorData() => _visitor ??=
      _getText(
            Uri.parse('$_site/tv'),
            headers: const {'User-Agent': kTvUserAgent},
          )
          .then((page) => _visitorIn.firstMatch(page)?.group(1))
          .catchError((Object e) {
            debugPrint('youtube visitor id: $e');
            return null;
          })
          .then((v) {
            if (v == null) _visitor = null;
            return v;
          });

  /// The home of the profile [accessToken] signs in to ([pageId] for a brand
  /// account): YouTube's own for the TV, as [parseBrowse] reads it. Without
  /// a visitor id the call goes without one.
  Future<List<MediaItem>> browse(String accessToken, {String? pageId}) async =>
      parseBrowse(await _browse('default', accessToken, pageId));

  /// The videos of the profile's history it stopped partway through, as
  /// [parseHistory] reads them.
  Future<List<MediaItem>> history(String accessToken, {String? pageId}) async =>
      parseHistory(await _browse('FEhistory', accessToken, pageId));

  Future<Map<String, dynamic>> _browse(
    String browseId,
    String accessToken,
    String? pageId,
  ) async {
    final visitor = await _visitorData();
    return _post(
      Uri.parse('$_site/youtubei/v1/browse?prettyPrint=false'),
      {
        'context': tvContext(visitorData: visitor),
        'racyCheckOk': true,
        'contentCheckOk': true,
        'browseId': browseId,
      },
      headers: {
        ...tvHeaders(accessToken, pageId: pageId),
        'X-Goog-Visitor-Id': ?visitor,
      },
    );
  }

  /// The videos YouTube finds for [query], as [parseSearch] reads them: as
  /// the profile [accessToken] signs in to ([pageId] for a brand account),
  /// else anonymously.
  Future<List<MediaItem>> search(
    String query, {
    String? accessToken,
    String? pageId,
  }) async {
    final visitor = await _visitorData();
    final json = await _post(
      Uri.parse('$_site/youtubei/v1/search?prettyPrint=false'),
      {'context': tvContext(visitorData: visitor), 'query': query},
      headers: {
        ...tvHeaders(accessToken, pageId: pageId),
        'X-Goog-Visitor-Id': ?visitor,
      },
    );
    return parseSearch(json);
  }
}

/// The videos of a TV `browse` answer, shelf after shelf, at most 20. Shorts,
/// channels, playlists, mixes and items that are neither tiles nor lockups
/// are left out; an answer without shelves has none.
List<MediaItem> parseBrowse(Map<String, dynamic> json) {
  // A video can sit on more than one shelf: it shows once.
  final seen = <String>{};
  return _videos(json).where((v) => seen.add(v.id)).take(20).toList();
}

/// The videos of a TV `search` answer, as [parseBrowse] has them. Checked
/// live (anonymous, 2026-11-01): `contents.sectionListRenderer` with shelves
/// of `lockupViewModel`s.
List<MediaItem> parseSearch(Map<String, dynamic> json) => parseBrowse(json);

/// The videos of a TV `FEhistory` answer watched partway (1 to 94 %), in the
/// order of the history, at most 20. Not checked live: the shape is
/// SmartTube's (a tile's `thumbnailOverlayResumePlaybackRenderer`).
List<MediaItem> parseHistory(Map<String, dynamic> json) => _videos(json)
    .where(
      (v) => switch (((v.progress ?? 0) * 100).round()) {
        >= 1 && <= 94 => true,
        _ => false,
      },
    )
    .take(20)
    .toList();

/// The videos of the shelves of an answer (or of its grid), in order: the
/// browse shape (`tvSurfaceContentRenderer`) or the search one (`contents`
/// itself).
Iterable<MediaItem> _videos(Map<String, dynamic> json) sync* {
  final content = switch (json) {
    {
      'contents': {
        'tvBrowseRenderer': {
          'content': {'tvSurfaceContentRenderer': {'content': final c}},
        },
      },
    } =>
      c,
    _ => json['contents'],
  };
  final lists = switch (content) {
    {'sectionListRenderer': {'contents': final List sections}} => [
      for (final section in sections)
        if (section case {'shelfRenderer': final Map shelf}
            when !_promoted(shelf))
          shelf['content'],
    ],
    _ => [content],
  };
  for (final list in lists) {
    final items = switch (list) {
      {'horizontalListRenderer': {'items': final List i}} ||
      {'gridRenderer': {'items': final List i}} ||
      {'expandedShelfContentsRenderer': {'items': final List i}} => i,
      _ => const [],
    };
    for (final item in items) {
      final video = switch (item) {
        {'tileRenderer': final Map tile} => _video(tile),
        {'lockupViewModel': final Map l} => _lockup(l),
        _ => null,
      };
      if (video != null) yield video;
    }
  }
}

/// A shelf YouTube is paid to show ("Explore the latest from Daddy Yankee",
/// badged "YouTube featured"): not the profile's recommendations. The badge
/// style is checked, its label is in the app's language.
bool _promoted(Map shelf) =>
    jsonEncode(shelf['headerRenderer'] ?? '').contains('BADGE_STYLE_TYPE_YPC');

/// A lockup that is a video (a music one too), else null.
MediaItem? _lockup(Map lockup) {
  final id = switch (lockup) {
    {
      'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO' || 'LOCKUP_CONTENT_TYPE_MUSIC',
      'contentId': final String id,
    } =>
      id,
    _ => null,
  };
  if (id == null) return null;
  final (title, rows) = switch (lockup['metadata']) {
    {'lockupMetadataViewModel': final Map m} => (
      switch (m['title']) {
        {'content': final String s} => s,
        _ => null,
      },
      m['metadata'],
    ),
    _ => (null, null),
  };
  // The first row is the channel, then "views • age".
  final channel = switch (rows) {
    {
      'contentMetadataViewModel': {
        'metadataRows': [
          {'metadataParts': [{'text': {'content': final String s}}, ...]},
          ...,
        ],
      },
    } =>
      s,
    _ => null,
  };
  // The last source, the largest.
  // ponytail: the web's lockup shape, not seen on the TV yet.
  final progress = _percent(switch (lockup['contentImage']) {
    {'thumbnailViewModel': {'overlays': final List overlays}} => [
      for (final o in overlays)
        if (o case {
          'thumbnailBottomOverlayViewModel': {
            'progressBar': {
              'thumbnailOverlayProgressBarViewModel': {
                'startPercent': final num p,
              },
            },
          },
        })
          p,
    ],
    _ => const <num>[],
  });
  final thumb = switch (lockup['contentImage']) {
    {
      'thumbnailViewModel': {
        'image': {'sources': [..., {'url': final String url}]},
      },
    } =>
      url,
    _ => null,
  };
  return MediaItem(
    type: MediaType.video,
    id: id,
    title: title ?? '',
    posterUrl: thumb,
    backdropUrl: thumb,
    videoId: id,
    subtitle: channel,
    progress: progress,
  );
}

/// A tile that is a video, else null.
MediaItem? _video(Map tile) {
  if (tile
      case {'style': 'TILE_STYLE_YTLR_SHORTS'} ||
          {'onSelectCommand': {'reelWatchEndpoint': _}}) {
    return null;
  }
  final type = tile['contentType'];
  if (type == 'TILE_CONTENT_TYPE_CHANNEL' ||
      type == 'TILE_CONTENT_TYPE_PLAYLIST') {
    return null;
  }
  final id = switch (tile) {
    {'onSelectCommand': {'watchEndpoint': {'videoId': final String id}}} => id,
    {'contentType': 'TILE_CONTENT_TYPE_VIDEO', 'contentId': final String id} =>
      id,
    _ => null,
  };
  if (id == null) return null;
  final (title, lines) = switch (tile['metadata']) {
    {'tileMetadataRenderer': final Map m} => (_text(m['title']), m['lines']),
    _ => (null, null),
  };
  // The first line is the channel ("channel", then "views • age").
  final channel = switch (lines) {
    [
      {
        'lineRenderer': {
          'items': [{'lineItemRenderer': {'text': final text}}, ...],
        },
      },
      ...,
    ] =>
      _text(text),
    _ => null,
  };
  final progress = _percent(switch (tile['header']) {
    {'tileHeaderRenderer': {'thumbnailOverlays': final List overlays}} => [
      for (final o in overlays)
        if (o case {
          'thumbnailOverlayResumePlaybackRenderer': {
            'percentDurationWatched': final num p,
          },
        })
          p,
    ],
    _ => const <num>[],
  });
  final thumb = switch (tile['header']) {
    {'tileHeaderRenderer': {'thumbnail': final photo}} => _thumb(photo),
    _ => null,
  };
  return MediaItem(
    type: MediaType.video,
    id: id,
    title: title ?? '',
    // The TV's thumbs are 16:9, usually 1280x720: the card and the backdrop.
    posterUrl: thumb,
    backdropUrl: thumb,
    videoId: id,
    subtitle: channel,
    progress: progress,
  );
}

/// The first of [percents] as 0–1, or null.
double? _percent(List<num> percents) =>
    percents.isEmpty ? null : percents.first.clamp(0, 100) / 100;

/// The `accountItem`s of an `accounts_list` answer, each a [YtAccount] of
/// [refreshToken]. One with no name is left out.
List<YtAccount> parseAccounts(Map<String, dynamic> json, String refreshToken) {
  final List items;
  try {
    items =
        (((json['contents']
                    as List)[0]['accountSectionListRenderer']['contents']
                as List)[0]['accountItemSectionRenderer']['contents']
            as List?) ??
        const [];
  } catch (_) {
    return const [];
  }
  return [
    for (final item in items)
      if (item case {'accountItem': final Map a})
        if (_text(a['accountName']) case final name?)
          YtAccount(
            refreshToken: refreshToken,
            name: name,
            avatarUrl: _thumb(a['accountPhoto']),
            pageId: _pageId(a['serviceEndpoint']),
          ),
  ];
}

/// `simpleText`, else the `runs` joined.
String? _text(Object? item) => switch (item) {
  {'simpleText': final String s} => s,
  {'runs': final List runs} when runs.isNotEmpty => [
    for (final r in runs)
      if (r case {'text': final String s}) s,
  ].join(),
  _ => null,
};

/// The fourth thumbnail, as SmartTube picks, or the last of fewer; `//` URLs
/// get `https:`.
String? _thumb(Object? photo) {
  if (photo case {'thumbnails': final List t} when t.isNotEmpty) {
    if (t[t.length > 3 ? 3 : t.length - 1] case {'url': final String url}) {
      return url.startsWith('//') ? 'https:$url' : url;
    }
  }
  return null;
}

String? _pageId(Object? endpoint) {
  if (endpoint case {
    'selectActiveIdentityEndpoint': {'supportedTokens': final List tokens},
  }) {
    for (final t in tokens) {
      if (t case {'pageIdToken': {'pageId': final String id}}) return id;
    }
  }
  return null;
}

/// Adding a YouTube login from a phone: [start] shows a [code], a phone
/// approves it, and the profiles of that login come back as [choices] for the
/// person to pick from; [addChosen] keeps the picked ones in Settings.
class YoutubeSignIn extends ChangeNotifier {
  final Settings settings;
  final YoutubeTvClient client;

  /// The code to show while the TV waits for a phone, and until [addChosen].
  YtDeviceCode? code;

  /// The profiles of the approved login, waiting for [addChosen].
  List<YtAccount>? choices;

  /// Why the last sign-in ended: `expired` (nobody approved in time),
  /// `denied`, or `network` (no code could be had). [start] clears it.
  String? error;

  Timer? _timer;
  Duration _every = Duration.zero;
  Duration _waited = Duration.zero;
  bool _wanted = false;
  bool _polling = false;

  /// The approved login's refresh token, kept while its profiles are asked:
  /// a code is exchanged only once, so a failed ask retries with this.
  String? _refresh;

  YoutubeSignIn(this.settings, this.client);

  /// Asks for a code and waits for a phone, asking every `interval` seconds
  /// (5 more each time Google says to slow down) until `expiresIn` has passed
  /// with no approval.
  Future<void> start() async {
    cancel();
    error = null;
    notifyListeners();
    _wanted = true;
    final YtDeviceCode next;
    try {
      next = await client.deviceCode(settings.youtubeDeviceId);
    } catch (e) {
      debugPrint('youtube device code: $e');
      if (!_wanted) return;
      _wanted = false;
      error = 'network';
      notifyListeners();
      return;
    }
    if (!_wanted) return; // cancelled while the code was out
    code = next;
    _waited = Duration.zero;
    _schedule(Duration(seconds: next.interval));
    notifyListeners();
  }

  void _schedule(Duration every) {
    _timer?.cancel();
    _every = every;
    _timer = Timer.periodic(every, (_) => _tick());
  }

  /// One ask. One that fails on the network is asked again on the next tick;
  /// a tick that finds the last ask still out only counts the time.
  Future<void> _tick() async {
    final c = code;
    if (c == null) return;
    _waited += _every;
    // Once approved, the token is kept and the profiles asked until they come
    // or the person cancels: the code running out no longer matters.
    if (_refresh == null && _waited >= Duration(seconds: c.expiresIn)) {
      return _end('expired');
    }
    if (_polling) return;
    _polling = true;
    try {
      var refresh = _refresh;
      if (refresh == null) {
        refresh = await client.pollToken(c);
        if (code != c || refresh == null) return; // cancelled, or not yet
        _refresh = refresh;
      }
      final profiles = await client.accounts(refresh);
      if (code != c) return;
      _timer?.cancel();
      _timer = null;
      choices = profiles;
      notifyListeners();
    } on YtAuthError catch (e) {
      if (code != c) return;
      if (e == YtAuthError.slowDown) {
        _schedule(_every + const Duration(seconds: 5));
      } else {
        _end(e.name);
      }
    } catch (e) {
      debugPrint('youtube sign-in: $e');
    } finally {
      _polling = false;
    }
  }

  void _end(String why) {
    cancel();
    error = why;
    notifyListeners();
  }

  /// Keeps [chosen] in Settings, enabled; a profile already there (same page,
  /// or same name) is replaced, with the new token, not added twice.
  Future<void> addChosen(Iterable<YtAccount> chosen) async {
    final accounts = [...settings.youtubeAccounts];
    for (final a in chosen) {
      final fresh = a.copyWith(enabled: true);
      final i = accounts.indexWhere((old) => old.key == a.key);
      if (i < 0) {
        accounts.add(fresh);
      } else {
        accounts[i] = fresh;
      }
    }
    settings.youtubeAccounts = accounts;
    cancel();
    await settings.save();
  }

  /// Ends the sign-in: no more asks, no [code], no [choices], nothing added.
  /// An answer that arrives later is dropped. Safe at any time.
  void cancel() {
    _wanted = false;
    _timer?.cancel();
    _timer = null;
    _refresh = null;
    if (code != null || choices != null) {
      code = null;
      choices = null;
      notifyListeners();
    }
  }

  /// The app went to the background: the same as [cancel].
  void stop() => cancel();
}
