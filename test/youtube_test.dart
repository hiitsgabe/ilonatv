import 'dart:convert';
import 'dart:io';

import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/youtube.dart';
import 'package:ilonatv/data/youtube_tv.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/locale.dart';
import 'package:ilonatv/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

MediaItem _v(String id) => MediaItem(type: MediaType.video, id: id, title: id);

List<String> _ids(List<MediaItem> items) => [for (final v in items) v.id];

/// A browse answer with one shelf of [ids].
Map<String, dynamic> _shelf(Iterable<String> ids) => {
  'contents': {
    'tvBrowseRenderer': {
      'content': {
        'tvSurfaceContentRenderer': {
          'content': {
            'sectionListRenderer': {
              'contents': [
                {
                  'shelfRenderer': {
                    'content': {
                      'horizontalListRenderer': {
                        'items': [
                          for (final id in ids)
                            {
                              'tileRenderer': {
                                'contentType': 'TILE_CONTENT_TYPE_VIDEO',
                                'onSelectCommand': {
                                  'watchEndpoint': {'videoId': id},
                                },
                              },
                            },
                        ],
                      },
                    },
                  },
                },
              ],
            },
          },
        },
      },
    },
  },
};

/// A YouTube whose homes are [homes] (and histories [histories], none when
/// missing), by page id (or access token for an account without one): a
/// list, or something to throw. A refresh token in [revoked] is refused.
class _Client extends YoutubeTvClient {
  _Client(this.homes, [this.histories = const {}]) : super(store: MemStore());
  final Map<String, Object> homes;
  final Map<String, Object> histories;
  final revoked = <String>{};
  final asked = <String>[];
  final askedHistory = <String>[];

  @override
  Future<String> accessToken(String refreshToken) async {
    if (revoked.contains(refreshToken)) throw YtAuthError.revoked;
    return 'ACCESS:$refreshToken';
  }

  @override
  Future<List<MediaItem>> browse(String accessToken, {String? pageId}) async {
    final key = pageId ?? accessToken;
    asked.add(key);
    return switch (homes[key]) {
      final List<MediaItem> list => list,
      final Object e => throw e,
      null => throw StateError('no home for $key'),
    };
  }

  @override
  Future<List<MediaItem>> history(String accessToken, {String? pageId}) async {
    final key = pageId ?? accessToken;
    askedHistory.add(key);
    return switch (histories[key]) {
      final List<MediaItem> list => list,
      final Object e => throw e,
      null => const [],
    };
  }
}

/// A cache whose entries read as written long ago while [aged]; a write makes
/// them young.
class _AgedStore extends MemStore {
  var aged = false;

  @override
  Future<DateTime?> writtenAt(String name) async =>
      aged ? DateTime(2000) : super.writtenAt(name);

  @override
  Future<void> write(String name, Map<String, dynamic> json) {
    aged = false;
    return super.write(name, json);
  }
}

const _a = YtAccount(refreshToken: 'R1', name: 'Ana', pageId: 'PA');
const _b = YtAccount(refreshToken: 'R1', name: 'Brand', pageId: 'PB');
const _c = YtAccount(refreshToken: 'R2', name: 'Caio', pageId: 'PC');

void main() {
  group('parseBrowse', () {
    test('keeps the videos of the shelves, in order, and nothing else', () {
      final videos = parseBrowse(fixture('yt_browse.json'));
      // Not the Shorts (by style or by endpoint), the channel or the
      // playlist; a lockup is read as in search.
      expect(_ids(videos), [
        'VIDEO000001',
        'LOCKUP00001',
        'VIDEO000002',
        'VIDEO000003',
      ]);
      final [first, _, second, third] = videos;
      expect(first.toJson(), {
        'type': 'video',
        'id': 'VIDEO000001',
        'title': 'First video',
        'year': null,
        'genre': '',
        'rating': null,
        // The fourth thumb, with https.
        'posterUrl': 'https://i.ytimg.com/vi/VIDEO000001/hq720.jpg',
        'backdropUrl': 'https://i.ytimg.com/vi/VIDEO000001/hq720.jpg',
        'imdbId': null,
        'videoId': 'VIDEO000001',
        'subtitle': 'Channel One',
      });
      // The id from contentId, the last thumb of fewer than four.
      expect(
        [second.title, second.subtitle, second.posterUrl],
        [
          'Second video',
          'Channel Two',
          'https://i.ytimg.com/vi/VIDEO000002/hq720.jpg',
        ],
      );
      expect([third.subtitle, third.posterUrl], [null, null]);
    });

    test('an answer without shelves has no videos', () {
      expect(parseBrowse({}), isEmpty);
      expect(parseBrowse({'contents': 'x'}), isEmpty);
      // What an anonymous home is: a search bar and a nudge to sign in.
      expect(
        parseBrowse({
          'contents': {
            'tvBrowseRenderer': {
              'content': {
                'tvSurfaceContentRenderer': {
                  'content': {
                    'sectionListRenderer': {
                      'contents': [
                        {'searchBarRenderer': {}},
                        {'feedNudgeRenderer': {}},
                      ],
                    },
                  },
                },
              },
            },
          },
        }),
        isEmpty,
      );
    });

    test('a shelf badged "YouTube featured" is a promotion: left out', () {
      // Through JSON, as an answer comes: plain maps that take any value.
      Map<String, dynamic> plain(Object o) => jsonDecode(jsonEncode(o));
      final mine = plain(_shelf(['MINE1']));
      final promo = plain(_shelf(['PROMO1']));
      final sections =
          (mine['contents']['tvBrowseRenderer']['content']['tvSurfaceContentRenderer']['content']['sectionListRenderer']['contents']
              as List);
      final shelf =
          (promo['contents']['tvBrowseRenderer']['content']['tvSurfaceContentRenderer']['content']['sectionListRenderer']['contents']
                      as List)
                  .single
              as Map;
      // As the TV home of 2026-11-02 has it.
      shelf['shelfRenderer']['headerRenderer'] = {
        'shelfHeaderRenderer': {
          'avatarLockup': {
            'avatarLockupRenderer': {
              'title': {
                'runs': [
                  {'text': 'Explore the latest from Daddy Yankee'},
                ],
              },
              'badges': [
                {
                  'metadataBadgeRenderer': {
                    'style': 'BADGE_STYLE_TYPE_YPC_TRANSPARENT',
                    'label': 'YouTube featured',
                  },
                },
              ],
            },
          },
        },
      };
      sections.add(shelf);
      expect(_ids(parseBrowse(mine)), ['MINE1']);
    });

    test('a video on two shelves shows once', () {
      expect(_ids(parseBrowse(_shelf(['A', 'B', 'A', 'C', 'B']))), [
        'A',
        'B',
        'C',
      ]);
    });

    test('at most 20', () {
      expect(_ids(parseBrowse(_shelf([for (var i = 0; i < 25; i++) 'V$i']))), [
        for (var i = 0; i < 20; i++) 'V$i',
      ]);
    });
  });

  group('parseHistory', () {
    test('keeps the videos watched partway, in order, with how much', () {
      final videos = parseHistory(fixture('yt_history.json'));
      // Not the one with no progress, the ones at 95 and 100 %, the Short or
      // the channel; 1 and 94 % are in.
      expect(_ids(videos), [
        'HALFWAY0001',
        'LASTMINUTE1',
        'JUSTSTART01',
        'LOCKUP00001',
      ]);
      expect([for (final v in videos) v.progress], [0.37, 0.94, 0.01, 0.6]);
      final first = videos.first;
      expect(
        [first.title, first.subtitle, first.posterUrl],
        [
          'Halfway',
          'Channel One',
          'https://i.ytimg.com/vi/HALFWAY0001/hq720.jpg',
        ],
      );
      // The progress is kept in the cache.
      expect(first.toJson()['progress'], 0.37);
      expect(MediaItem.fromJson(first.toJson()).progress, 0.37);
      expect(MediaItem.fromJson(_v('x').toJson()).progress, isNull);
      expect(_v('x').toJson().containsKey('progress'), isFalse);
    });

    test('a grid is read too; at most 20; an odd answer has none', () {
      Map<String, dynamic> tile(int i) => {
        'tileRenderer': {
          'contentType': 'TILE_CONTENT_TYPE_VIDEO',
          'header': {
            'tileHeaderRenderer': {
              'thumbnailOverlays': [
                {
                  'thumbnailOverlayResumePlaybackRenderer': {
                    'percentDurationWatched': 50,
                  },
                },
              ],
            },
          },
          'onSelectCommand': {
            'watchEndpoint': {'videoId': 'V$i'},
          },
        },
      };
      expect(
        _ids(
          parseHistory({
            'contents': {
              'tvBrowseRenderer': {
                'content': {
                  'tvSurfaceContentRenderer': {
                    'content': {
                      'gridRenderer': {
                        'items': [for (var i = 0; i < 25; i++) tile(i)],
                      },
                    },
                  },
                },
              },
            },
          }),
        ),
        [for (var i = 0; i < 20; i++) 'V$i'],
      );
      expect(parseHistory({}), isEmpty);
      // The home's videos have no progress.
      expect(parseHistory(_shelf(['V1'])), isEmpty);
    });

    test('history asks for FEhistory as the TV', () async {
      final posts = <(Uri, Map<String, dynamic>, Map<String, String>)>[];
      final client = YoutubeTvClient(
        store: MemStore(),
        post: (uri, body, {headers = const {}}) async {
          posts.add((uri, body, headers));
          return fixture('yt_history.json');
        },
        getText: (uri, {headers = const {}}) async =>
            throw const SocketException('offline'),
      );
      final videos = await client.history('ACCESS', pageId: 'PAGE');
      expect(videos, hasLength(4));
      final (uri, body, headers) = posts.single;
      expect(
        '$uri',
        'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false',
      );
      expect(body['browseId'], 'FEhistory');
      expect(body['context']['client']['clientName'], 'TVHTML5');
      expect(
        [headers['Authorization'], headers['X-Goog-Pageid']],
        ['Bearer ACCESS', 'PAGE'],
      );
    });
  });

  group('parseSearch', () {
    test('keeps the videos, music ones too, and nothing else', () {
      final videos = parseSearch(fixture('yt_search.json'));
      // Not the mix, the channel, the continuation or the Short; a tile is
      // read as in browse.
      expect(_ids(videos), [
        'VIDEO000001',
        'VIDEO000002',
        'VIDEO000003',
        'VIDEO000004',
      ]);
      final [first, second, third, bare] = videos;
      expect(first.toJson(), {
        'type': 'video',
        'id': 'VIDEO000001',
        'title': 'First result',
        'year': null,
        'genre': '',
        'rating': null,
        // The last source, the largest.
        'posterUrl': 'https://i.ytimg.com/vi/VIDEO000001/hq720.jpg',
        'backdropUrl': 'https://i.ytimg.com/vi/VIDEO000001/hq720.jpg',
        'imdbId': null,
        'videoId': 'VIDEO000001',
        'subtitle': 'Channel One',
      });
      expect([second.title, second.subtitle], ['Second result', 'Channel Two']);
      expect(third.title, 'Third result');
      expect([bare.title, bare.subtitle, bare.posterUrl], ['', null, null]);
    });

    test('an odd answer has no videos; at most 20', () {
      expect(parseSearch({}), isEmpty);
      expect(
        parseSearch({
          'contents': {
            'sectionListRenderer': {
              'contents': [
                {'itemSectionRenderer': {}},
              ],
            },
          },
        }),
        isEmpty,
      );
      // The browse shape is read too.
      expect(_ids(parseSearch(_shelf(['V1']))), ['V1']);
      expect(
        parseSearch({
          'contents': {
            'sectionListRenderer': {
              'contents': [
                for (var s = 0; s < 3; s++)
                  {
                    'shelfRenderer': {
                      'content': {
                        'horizontalListRenderer': {
                          'items': [
                            for (var i = 0; i < 10; i++)
                              {
                                'lockupViewModel': {
                                  'contentType': 'LOCKUP_CONTENT_TYPE_VIDEO',
                                  'contentId': 'V$s$i',
                                },
                              },
                          ],
                        },
                      },
                    },
                  },
              ],
            },
          },
        }),
        hasLength(20),
      );
    });

    test('search asks as the TV, signed in or not', () async {
      final posts = <(Uri, Map<String, dynamic>, Map<String, String>)>[];
      final client = YoutubeTvClient(
        store: MemStore(),
        post: (uri, body, {headers = const {}}) async {
          posts.add((uri, body, headers));
          return fixture('yt_search.json');
        },
        getText: (uri, {headers = const {}}) async =>
            throw const SocketException('offline'),
      );
      final videos = await client.search(
        'lofi',
        accessToken: 'ACCESS',
        pageId: 'PAGE',
      );
      expect(videos, hasLength(4));
      final (uri, body, headers) = posts.single;
      expect(
        '$uri',
        'https://www.youtube.com/youtubei/v1/search?prettyPrint=false',
      );
      expect(body['query'], 'lofi');
      expect(body['context']['client']['clientName'], 'TVHTML5');
      expect(headers, {
        'User-Agent': kTvUserAgent,
        'Referer': 'https://www.youtube.com/tv',
        'Authorization': 'Bearer ACCESS',
        'X-Goog-Pageid': 'PAGE',
      });

      await client.search('lofi');
      expect(posts.last.$3, {
        'User-Agent': kTvUserAgent,
        'Referer': 'https://www.youtube.com/tv',
      });
    });
  });

  group('browse', () {
    late List<(Uri, Map<String, dynamic>, Map<String, String>)> posts;
    late List<Uri> pages;
    late Object tvPage;
    late YoutubeTvClient client;

    setUp(() {
      I18n.language = 'pt';
      deviceLocale = () => 'en_CA';
      posts = [];
      pages = [];
      tvPage = File('test/fixtures/yt_tv.html').readAsStringSync();
      client = YoutubeTvClient(
        store: MemStore(),
        post: (uri, body, {headers = const {}}) async {
          posts.add((uri, body, headers));
          return fixture('yt_browse.json');
        },
        getText: (uri, {headers = const {}}) async {
          pages.add(uri);
          if (tvPage case final String page) return page;
          throw tvPage;
        },
      );
    });
    tearDown(() {
      I18n.language = 'en';
      deviceLocale = () => Platform.localeName;
    });

    test('asks for the home as the TV, with the visitor id of /tv', () async {
      final videos = await client.browse('ACCESS', pageId: 'PAGE');
      expect(videos, hasLength(4));
      final (uri, body, headers) = posts.single;
      expect(
        '$uri',
        'https://www.youtube.com/youtubei/v1/browse?prettyPrint=false',
      );
      expect(headers, {
        'User-Agent': kTvUserAgent,
        'Referer': 'https://www.youtube.com/tv',
        'Authorization': 'Bearer ACCESS',
        'X-Goog-Pageid': 'PAGE',
        'X-Goog-Visitor-Id': 'VISITOR%3D%3D',
      });
      expect({...body}..remove('context'), {
        'racyCheckOk': true,
        'contentCheckOk': true,
        'browseId': 'default',
      });
      final c = body['context']['client'] as Map;
      expect(
        [
          c['clientName'],
          c['clientVersion'],
          c['acceptLanguage'],
          c['acceptRegion'],
          c['visitorData'],
        ],
        // The app's language, the device's country.
        ['TVHTML5', kTvClientVersion, 'pt', 'CA', 'VISITOR%3D%3D'],
      );

      // /tv is asked once a run.
      await client.browse('ACCESS');
      expect(pages, hasLength(1));
      expect(posts.last.$3.containsKey('X-Goog-Pageid'), isFalse);
    });

    test('the region is the country of the device locale, else US', () {
      String region(String locale) {
        deviceLocale = () => locale;
        return tvContext()['client']['acceptRegion'] as String;
      }

      expect(
        [region('pt_BR'), region('en-ca'), region('fr_FR.UTF-8'), region('C')],
        ['BR', 'CA', 'FR', 'US'],
      );
    });

    test(
      'without /tv the call goes without a visitor id, asked again next time',
      () async {
        tvPage = const SocketException('offline');
        await client.browse('ACCESS');
        expect(posts.single.$3.containsKey('X-Goog-Visitor-Id'), isFalse);
        expect(
          (posts.single.$2['context']['client'] as Map).containsKey(
            'visitorData',
          ),
          isFalse,
        );

        tvPage = File('test/fixtures/yt_tv.html').readAsStringSync();
        await client.browse('ACCESS');
        expect(pages, hasLength(2));
        expect(posts.last.$3['X-Goog-Visitor-Id'], 'VISITOR%3D%3D');
      },
    );
  });

  group('YoutubeSource', () {
    late Settings settings;
    late MemStore store;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      settings = await Settings.load();
      store = MemStore();
    });

    test('mixes the enabled accounts one at a time, no video twice', () async {
      settings.youtubeAccounts = [_a, _b, _c.copyWith(enabled: false)];
      final client = _Client({
        'PA': [_v('a1'), _v('a2'), _v('both'), _v('a3')],
        'PB': [_v('b1'), _v('both'), _v('b2')],
        'PC': [_v('c1')],
      });
      final source = YoutubeSource(settings, store, client);
      await source.refresh();
      expect(_ids(source.videos), ['a1', 'b1', 'a2', 'both', 'b2', 'a3']);
      expect(client.asked, unorderedEquals(['PA', 'PB']));
    });

    test('20 in all', () async {
      settings.youtubeAccounts = [_a, _b];
      final source = YoutubeSource(
        settings,
        store,
        _Client({
          'PA': [for (var i = 0; i < 15; i++) _v('a$i')],
          'PB': [for (var i = 0; i < 15; i++) _v('b$i')],
        }),
      );
      await source.refresh();
      expect(_ids(source.videos), [
        for (var i = 0; i < 10; i++) ...['a$i', 'b$i'],
      ]);
    });

    test(
      'continue watching: the histories mixed the same way, and cached',
      () async {
        settings.youtubeAccounts = [_a, _b, _c.copyWith(enabled: false)];
        final client = _Client(
          {
            'PA': [_v('a1')],
            'PB': [_v('b1')],
            'PC': [_v('c1')],
          },
          {
            'PA': [_v('h1'), _v('both'), _v('h2')],
            'PB': [_v('both'), _v('k1')],
            'PC': [_v('off')],
          },
        );
        final source = YoutubeSource(settings, store, client);
        await source.refresh();
        expect(_ids(source.continueWatching), ['h1', 'both', 'k1', 'h2']);
        expect(_ids(source.videos), ['a1', 'b1']);

        // From the cache; a history that fails keeps the cached one.
        final again = YoutubeSource(
          settings,
          store,
          _Client(
            {
              'PA': [_v('a1')],
              'PB': [_v('b1')],
            },
            {'PA': const SocketException('offline'), 'PB': <MediaItem>[]},
          ),
        );
        await again.loadCache();
        expect(_ids(again.continueWatching), ['h1', 'both', 'k1', 'h2']);
        await again.refresh(force: true);
        expect(_ids(again.continueWatching), ['h1', 'both', 'h2']);
        expect(_ids(again.videos), ['a1', 'b1']);
      },
    );

    test('a cache from before the histories still opens the row', () async {
      settings.youtubeAccounts = [_a];
      await store.write('youtube', {
        'lists': {
          'PA': [_v('a1').toJson()],
        },
        'revoked': {},
      });
      final source = YoutubeSource(settings, store, _Client({}));
      await source.loadCache();
      expect(_ids(source.videos), ['a1']);
      expect(source.continueWatching, isEmpty);
    });

    test('a young cache from before the histories is asked again', () async {
      settings.youtubeAccounts = [_a];
      await store.write('youtube', {
        'lists': {
          'PA': [_v('a1').toJson()],
        },
        'revoked': {},
      });
      final client = _Client(
        {
          'PA': [_v('a1')],
        },
        {
          'PA': [_v('h1')],
        },
      );
      final source = YoutubeSource(settings, store, client);
      await source.loadCache();
      await source.refresh();
      expect(client.askedHistory, ['PA']);
      expect(_ids(source.continueWatching), ['h1']);

      // Now with both lists: young.
      await source.refresh();
      expect(client.askedHistory, ['PA']);
    });

    test('an account turned off leaves the row; none on, no row', () async {
      settings.youtubeAccounts = [_a, _b];
      final client = _Client({
        'PA': [_v('a1')],
        'PB': [_v('b1')],
      });
      final source = YoutubeSource(settings, store, client);
      await source.refresh();
      expect(_ids(source.videos), ['a1', 'b1']);

      settings.youtubeAccounts = [_a.copyWith(enabled: false), _b];
      await settings.save();
      expect(_ids(source.videos), ['b1']);

      settings.youtubeAccounts = [];
      await settings.save();
      await pumpEventQueue();
      expect(source.videos, isEmpty);
      expect(client.asked, ['PA', 'PB'], reason: 'nothing asked again');
    });

    test('an account turned on is asked for at once', () async {
      settings.youtubeAccounts = [_a];
      final client = _Client({
        'PA': [_v('a1')],
        'PC': [_v('c1')],
      });
      final source = YoutubeSource(settings, store, client);
      await source.refresh();
      settings.youtubeAccounts = [_a, _c];
      await settings.save();
      await pumpEventQueue();
      expect(_ids(source.videos), ['a1', 'c1']);
      expect(client.asked, ['PA', 'PC'], reason: 'PA has its list');

      // Any other save asks nothing.
      await settings.save();
      await pumpEventQueue();
      expect(client.asked, ['PA', 'PC']);
    });

    test(
      'a refresh that gets nothing new leaves the cache as old as it was',
      () async {
        settings.youtubeAccounts = [_a];
        final store = _AgedStore();
        await store.write('youtube', {
          'lists': {
            'PA': [_v('a1').toJson()],
          },
          'revoked': {},
        });
        store.aged = true; // written long ago
        final client = _Client({'PA': const SocketException('offline')});
        final source = YoutubeSource(settings, store, client);
        await source.loadCache();
        await source.refresh();
        await source.refresh();
        expect(client.asked, ['PA', 'PA']);
        expect(_ids(source.videos), ['a1']);
      },
    );

    test('refreshes run one at a time', () async {
      settings.youtubeAccounts = [_a];
      final client = _Client({
        'PA': [_v('a1')],
      });
      final source = YoutubeSource(settings, store, client);
      // The second finds the first's list and cache.
      await Future.wait([source.refresh(), source.refresh()]);
      expect(client.asked, ['PA']);
    });

    test(
      'the cache opens the row, and a young one is not asked again',
      () async {
        settings.youtubeAccounts = [_a, _b];
        await YoutubeSource(
          settings,
          store,
          _Client({
            'PA': [_v('a1')],
            'PB': [_v('b1')],
          }),
        ).refresh();

        final client = _Client({});
        final source = YoutubeSource(settings, store, client);
        await source.loadCache();
        expect(_ids(source.videos), ['a1', 'b1']);
        await source.refresh();
        expect(client.asked, isEmpty);
      },
    );

    test(
      'an account that fails keeps its cached list; with none it is left out',
      () async {
        settings.youtubeAccounts = [_a, _b];
        await store.write('youtube', {
          'lists': {
            'PA': [_v('a1').toJson()],
          },
          'revoked': {},
        });
        final client = _Client({
          'PA': const SocketException('offline'),
          'PB': const SocketException('offline'),
        });
        final source = YoutubeSource(settings, store, client);
        await source.loadCache();
        await source.refresh(force: true);
        expect(_ids(source.videos), ['a1']);
        expect(client.asked, unorderedEquals(['PA', 'PB']));
      },
    );

    test('all failing with no cache: no row', () async {
      settings.youtubeAccounts = [_a];
      final source = YoutubeSource(
        settings,
        store,
        _Client({'PA': const SocketException('offline')}),
      );
      await source.refresh();
      expect(source.videos, isEmpty);
    });

    test('a cache this version cannot read is skipped', () async {
      settings.youtubeAccounts = [_a];
      // The Data API row's cache.
      await store.write('youtube', {
        'videos': [_v('old').toJson()],
        'region': 'CA',
      });
      final source = YoutubeSource(settings, store, _Client({}));
      await source.loadCache();
      expect(source.videos, isEmpty);
    });

    test(
      'a revoked account leaves the row, marked, until it signs in again',
      () async {
        settings.youtubeAccounts = [_a, _c];
        final client = _Client({
          'PA': [_v('a1')],
          'PC': [_v('c1')],
        });
        final source = YoutubeSource(settings, store, client);
        await source.refresh();
        expect(_ids(source.videos), ['a1', 'c1']);

        client.revoked.add('R2');
        await source.refresh(force: true);
        expect(_ids(source.videos), ['a1']);
        expect([source.isRevoked(_a), source.isRevoked(_c)], [false, true]);
        expect(settings.youtubeAccounts, hasLength(2), reason: 'not deleted');

        // Kept on disk as a hash, never the token, and not asked again.
        final written = jsonEncode(await store.read('youtube'));
        expect(written, isNot(contains('R2')));
        expect(written, contains('revokedHash'));
        final again = YoutubeSource(settings, store, client);
        await again.loadCache();
        expect(again.isRevoked(_c), isTrue);
        client.asked.clear();
        await again.refresh(force: true);
        expect(client.asked, ['PA']);

        // Signed in again: a new refresh token.
        const back = YtAccount(refreshToken: 'R3', name: 'Caio', pageId: 'PC');
        settings.youtubeAccounts = [_a, back];
        await settings.save();
        await pumpEventQueue();
        expect(again.isRevoked(back), isFalse);
        expect(_ids(again.videos), ['a1', 'c1']);
      },
    );

    test('a cache from before the hashes revokes no one', () async {
      settings.youtubeAccounts = [_c];
      await store.write('youtube', {
        'lists': {
          'PC': [_v('c1').toJson()],
        },
        'revoked': {'PC': 'R2'},
      });
      final source = YoutubeSource(settings, store, _Client({}));
      await source.loadCache();
      expect(source.isRevoked(_c), isFalse);
      expect(_ids(source.videos), ['c1']);
    });

    test('start asks, then every 30 minutes; stop stops', () async {
      settings.youtubeAccounts = [_a];
      final client = _Client({
        'PA': [_v('a1')],
      });
      final source = YoutubeSource(settings, store, client);
      final zone = FakeTimerZone();
      await zone.run(() async {
        source.start();
        await pumpEventQueue();
        source.start(); // safe again: one timer
        await pumpEventQueue();
        expect(zone.timers.map((t) => t.period), [const Duration(minutes: 30)]);
        expect(client.asked, ['PA'], reason: 'the second start finds it fresh');

        // The tick asks however young the cache is.
        await zone.timers.single.fireAndSettle();
        expect(client.asked, ['PA', 'PA']);

        source.stop();
        expect(zone.timers.single.isActive, isFalse);
      });
      source.stop(); // safe twice
    });
  });
}
