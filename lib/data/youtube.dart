import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../settings.dart';
import '../store.dart';
import 'media.dart';
import 'sports.dart' show plainName;
import 'youtube_tv.dart';

/// How often the open app asks again, and how old the cache may be at start.
const _every = Duration(minutes: 30);

const _cache = 'youtube';

/// The YouTube row of the home: the home of each enabled account of Settings,
/// mixed one account at a time with no video twice, 20 in all. Each account's
/// last list is cached on disk, so the home opens with them; the open app asks
/// again every 30 minutes. An account whose list cannot be had keeps its
/// cached one; one that was signed out ([isRevoked]) leaves the mix. The
/// videos of their histories watched partway ([continueWatching]) are mixed,
/// cached and asked for the same way, with the homes.
class YoutubeSource extends ChangeNotifier {
  final Settings settings;
  final Store store;
  final YoutubeTvClient client;
  Timer? _timer;

  List<MediaItem> videos = [];
  List<MediaItem> continueWatching = [];

  /// The last list (and history) of each account, by [YtAccount.key].
  final _lists = <String, List<MediaItem>>{};
  final _history = <String, List<MediaItem>>{};

  /// The hash ([_hash]) of the refresh token YouTube refused, by
  /// [YtAccount.key]: signing in again gives the account a new one, which is
  /// not refused. The cache keeps no token.
  final _revoked = <String, String>{};

  /// The last refresh queued: refreshes run one after another, never two at
  /// once.
  Future<void>? _refreshing;

  YoutubeSource(this.settings, this.store, this.client) {
    // An account turned on, off, added or removed shows at once; only one
    // with no list yet is asked for.
    settings.addListener(() {
      _mix();
      _queue(() => _refresh(missingOnly: true)).ignore();
    });
  }

  /// For the voice assistant. [what] 'history': the videos of [query]'s
  /// channel (or title) the accounts have in their histories, newest first,
  /// from the last refresh; anything else: YouTube's own search, signed in as
  /// the first account on the home so results fit the person.
  Future<List<MediaItem>> assistantSearch(String query, String what) async {
    final a = _mixed.firstOrNull;
    if (what == 'history') {
      final words = _words(query);
      return [
        for (final list in _history.values)
          for (final v in list)
            if (words.every(
              (w) =>
                  _words('${v.subtitle} ${v.title}')
                      .any((x) => x.startsWith(w)),
            ))
              v,
      ];
    }
    final token = a == null ? null : await client.accessToken(a.refreshToken);
    return client.search(query, accessToken: token, pageId: a?.pageId);
  }

  /// Lower-case words without accents, so "Linus tech" matches "Linus Tech Tips".
  static List<String> _words(String s) => plainName(s).split(' ');

  /// [account] must sign in again: its refresh token was refused.
  bool isRevoked(YtAccount account) =>
      _revoked[account.key] == _hash(account.refreshToken);

  /// The accounts that make the row.
  List<YtAccount> get _mixed => [
    for (final a in settings.youtubeAccounts)
      if (a.enabled && !isRevoked(a)) a,
  ];

  /// Shows what the last run cached, of any age. A cache this version cannot
  /// read is skipped as a whole.
  Future<void> loadCache() async {
    try {
      final cached = await store.read(_cache);
      if (cached == null) return;
      Map<String, List<MediaItem>> read(Map map) => {
        for (final MapEntry(:key, :value) in map.entries)
          key as String: [
            for (final json in value as List) MediaItem.fromJson(json),
          ],
      };
      final lists = read(cached['lists'] as Map);
      // A cache from before the histories has none.
      final history = read(cached['history'] as Map? ?? const {});
      // A cache from before the hashes kept raw tokens under 'revoked': not
      // read, so its accounts count as not revoked until refused again.
      final revoked = (cached['revokedHash'] as Map? ?? const {})
          .cast<String, String>();
      _lists.addAll(lists);
      _history.addAll(history);
      _revoked.addAll(revoked);
      _mix();
    } catch (_) {}
  }

  /// Asks for the home of each account of the row, unless each has a list and
  /// the cache is under 30 minutes old; [force] asks anyway. An account that
  /// fails keeps the list it had; a revoked one leaves the row. One asked
  /// while another runs waits for it.
  Future<void> refresh({bool force = false}) =>
      _queue(() => _refresh(force: force));

  Future<void> _queue(Future<void> Function() run) {
    final next = (_refreshing ?? Future<void>.value()).then((_) => run());
    _refreshing = next;
    return next.whenComplete(() {
      if (_refreshing == next) _refreshing = null;
    });
  }

  /// [missingOnly] asks only the accounts with no list.
  Future<void> _refresh({bool force = false, bool missingOnly = false}) async {
    var accounts = _mixed;
    if (missingOnly) {
      accounts = [
        for (final a in accounts)
          if (!_lists.containsKey(a.key)) a,
      ];
    } else if (!force && accounts.every((a) => _lists.containsKey(a.key))) {
      try {
        // Fresh only with both lists of each account: a cache from before the
        // histories is stale.
        final fresh = await store.freshOrNull(_cache, _every);
        bool has(String list, YtAccount a) =>
            (fresh?[list] as Map?)?.containsKey(a.key) ?? false;
        if (accounts.every((a) => has('lists', a) && has('history', a))) {
          return;
        }
      } catch (_) {}
    }
    if (accounts.isEmpty) return;
    final changed = await Future.wait([for (final a in accounts) _ask(a)]);
    _mix();
    // Nothing new: the cache keeps its age, so the next refresh asks again.
    if (!changed.contains(true)) return;
    // Last, so a cache that will not write (a full disk) cannot undo a good
    // fetch.
    final keys = {for (final a in settings.youtubeAccounts) a.key};
    Map<String, List> write(Map<String, List<MediaItem>> lists) => {
      for (final MapEntry(:key, :value) in lists.entries)
        if (keys.contains(key)) key: [for (final v in value) v.toJson()],
    };
    try {
      await store.write(_cache, {
        'lists': write(_lists),
        'history': write(_history),
        'revokedHash': {
          for (final MapEntry(:key, :value) in _revoked.entries)
            if (keys.contains(key)) key: value,
        },
      });
    } catch (_) {}
  }

  /// True when [a] got a list or was found revoked.
  Future<bool> _ask(YtAccount a) async {
    try {
      final token = await client.accessToken(a.refreshToken);
      _lists[a.key] = await client.browse(token, pageId: a.pageId);
      try {
        _history[a.key] = await client.history(token, pageId: a.pageId);
      } catch (e) {
        // The home is had: the history keeps what it had.
        debugPrint('youtube history ${a.name}: $e');
      }
      return true;
    } on YtAuthError catch (e) {
      if (e != YtAuthError.revoked) return false;
      _revoked[a.key] = _hash(a.refreshToken);
      _lists.remove(a.key);
      _history.remove(a.key);
      return true;
    } catch (e) {
      // ponytail: no retry; the next tick or resume asks again.
      debugPrint('youtube ${a.name}: $e');
      return false;
    }
  }

  /// [videos] and [continueWatching] from the lists of the accounts of the
  /// row.
  void _mix() {
    final home = _interleave(_lists);
    final history = _interleave(_history);
    if (listEquals(home, videos) && listEquals(history, continueWatching)) {
      return;
    }
    videos = home;
    continueWatching = history;
    notifyListeners();
  }

  /// The first of each of [lists] in the order of Settings, then the second
  /// of each, and so on, with no video twice, 20 in all.
  List<MediaItem> _interleave(Map<String, List<MediaItem>> lists) {
    final mixing = [for (final a in _mixed) ?lists[a.key]];
    final seen = <String>{};
    final mixed = <MediaItem>[];
    for (var i = 0; mixed.length < 20 && mixing.any((l) => i < l.length); i++) {
      for (final l in mixing) {
        if (i < l.length && mixed.length < 20 && seen.add(l[i].id)) {
          mixed.add(l[i]);
        }
      }
    }
    return mixed;
  }

  /// Refreshes at once, if due, and then every 30 minutes. Safe to call again.
  void start() {
    refresh().ignore();
    // The tick forces: it comes just under 30 minutes after the cache was
    // written, which would still count as fresh.
    _timer ??= Timer.periodic(_every, (_) => refresh(force: true).ignore());
  }

  /// Safe without a [start].
  void stop() {
    _timer?.cancel();
    _timer = null;
  }
}

/// FNV-1a 64 of the UTF-8 bytes of [s], in hex: stable across runs, unlike
/// [String.hashCode].
// ponytail: not a cryptographic hash; it only keeps the token off the disk.
String _hash(String s) {
  var h = 0xcbf29ce484222325;
  for (final b in utf8.encode(s)) {
    h = (h ^ b) * 0x100000001b3;
  }
  String half(int v) => v.toRadixString(16).padLeft(8, '0');
  return half(h >>> 32) + half(h & 0xffffffff);
}
