import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

final latestRelease = Uri.parse(
  'https://api.github.com/repos/hiitsgabe/ilonatv/releases/latest',
);
const releasePage = 'https://github.com/hiitsgabe/ilonatv/releases/latest';

/// Where every release asset must come from: an answer pointing anywhere
/// else is no asset.
const releaseDownloads =
    'https://github.com/hiitsgabe/ilonatv/releases/download/';
const _stall = Duration(seconds: 30);

class ReleaseAsset {
  const ReleaseAsset({
    required this.url,
    required this.size,
    required this.version,
    required this.sha256,
  });

  final Uri url;
  final int size;

  /// The release tag, like v0.6.1.
  final String version;
  final String sha256;
}

/// The latest release has no such APK, or no checksum for it.
class NoAsset implements Exception {
  const NoAsset();
}

/// GitHub answered 403 or 429: unauthenticated calls get 60 an hour per IP.
class RateLimited implements Exception {
  const RateLimited();
}

class BadChecksum implements Exception {
  const BadChecksum();
}

/// The installer's view of GitHub Releases, so tests can stand in for it.
class ReleaseSource {
  const ReleaseSource();

  Future<ReleaseAsset?> latest(String abi) => latestTvApk(abi);

  /// The latest release's asset [name], like ilonatv-companion.apk.
  Future<ReleaseAsset?> named(String name) => latestApk(name);

  Future<File> fetch(
    ReleaseAsset a,
    File to, {
    void Function(int received, int total)? progress,
  }) => download(a, to, progress: progress);
}

/// The TV's APK for [abi]; null when the repository has no release yet.
Future<ReleaseAsset?> latestTvApk(
  String abi, {
  HttpClient? http,
  Uri? url,
  String downloads = releaseDownloads,
}) => latestApk('ilonatv-$abi.apk', http: http, url: url, downloads: downloads);

/// The latest release's asset [name]; null when there is no release yet.
Future<ReleaseAsset?> latestApk(
  String name, {
  HttpClient? http,
  Uri? url,
  String downloads = releaseDownloads,
}) async {
  final client = http ?? HttpClient();
  client.userAgent = 'IlonaTV-Companion';
  try {
    return await _latest(
      client,
      name,
      url ?? latestRelease,
      downloads,
    ).timeout(const Duration(seconds: 15));
  } finally {
    if (http == null) client.close(force: true);
  }
}

Future<ReleaseAsset?> _latest(
  HttpClient client,
  String name,
  Uri url,
  String downloads,
) async {
  final (status, body) = await _get(client, url, api: true);
  if (status == 404) return null;
  if (status == 403 || status == 429) throw const RateLimited();
  if (status != 200) throw HttpException('GitHub answered $status', uri: url);
  final release = jsonDecode(body) as Map<String, Object?>;
  final assets = (release['assets'] as List).cast<Map<String, Object?>>();
  Map<String, Object?>? named(String n) =>
      assets.where((a) => a['name'] == n).firstOrNull;
  Uri? from(Map<String, Object?>? a) {
    final u = a?['browser_download_url'];
    return u is String && u.startsWith(downloads) ? Uri.parse(u) : null;
  }

  final apk = named(name);
  final apkUrl = from(apk);
  if (apk == null || apkUrl == null) throw const NoAsset();
  final digest = apk['digest'] as String?;
  var sum = digest != null && digest.startsWith('sha256:')
      ? digest.substring(7)
      : null;
  final sums = named('SHA256SUMS');
  final sumsUrl = from(sums);
  if (sum == null && sumsUrl != null) {
    final (s, text) = await _get(client, sumsUrl);
    if (s != 200) throw HttpException('SHA256SUMS answered $s', uri: sumsUrl);
    sum = RegExp(
      '^([0-9a-fA-F]{64}) [ *]${RegExp.escape(name)}\$',
      multiLine: true,
    ).firstMatch(text)?.group(1);
  }
  if (sum == null) throw const NoAsset();
  return ReleaseAsset(
    url: apkUrl,
    size: apk['size'] as int,
    version: release['tag_name'] as String,
    sha256: sum.toLowerCase(),
  );
}

Future<(int, String)> _get(
  HttpClient client,
  Uri url, {
  bool api = false,
}) async {
  final req = await client.getUrl(url);
  if (api) {
    req.headers.set(HttpHeaders.acceptHeader, 'application/vnd.github+json');
  }
  final res = await req.close();
  return (res.statusCode, await res.transform(utf8.decoder).join());
}

/// Streams [a] into [to] and checks its SHA-256; on any failure [to] is deleted.
Future<File> download(
  ReleaseAsset a,
  File to, {
  void Function(int received, int total)? progress,
  HttpClient? http,
  Duration stall = _stall,
}) async {
  final client = http ?? HttpClient();
  client.userAgent = 'IlonaTV-Companion';
  try {
    final req = await client.getUrl(a.url).timeout(stall);
    final res = await req.close().timeout(stall);
    if (res.statusCode != 200) {
      throw HttpException('download answered ${res.statusCode}', uri: a.url);
    }
    Digest? digest;
    final hash = sha256.startChunkedConversion(
      ChunkedConversionSink<Digest>.withCallback((d) => digest = d.single),
    );
    final sink = to.openWrite();
    var got = 0;
    try {
      await for (final chunk in res.timeout(stall)) {
        hash.add(chunk);
        sink.add(chunk);
        got += chunk.length;
        progress?.call(got, a.size);
      }
    } finally {
      await sink.close();
    }
    hash.close();
    if ('$digest' != a.sha256) throw const BadChecksum();
    return to;
  } catch (_) {
    if (to.existsSync()) to.deleteSync();
    rethrow;
  } finally {
    if (http == null) client.close(force: true);
  }
}

/// Downloads [a] into [dir] and hands it to [install] only once its SHA-256
/// matched; a mismatch throws [BadChecksum] and leaves no file, and so does
/// an [install] or a [progress] that throws (a page left mid-download).
Future<void> selfUpdate(
  ReleaseSource releases,
  ReleaseAsset a,
  String dir,
  Future<void> Function(String path) install, {
  void Function(int received, int total)? progress,
}) async {
  final f = await releases.fetch(
    a,
    File('$dir/update.apk'),
    progress: progress,
  );
  try {
    await install(f.path);
  } catch (_) {
    if (f.existsSync()) f.deleteSync();
    rethrow;
  }
}

/// The APK's ABI for a device's comma-separated list (getprop's abilist,
/// Build.SUPPORTED_ABIS): arm64 first; null when it has neither.
String? pickAbi(String abilist) {
  final abis = abilist.trim().split(',');
  for (final a in ['arm64-v8a', 'armeabi-v7a']) {
    if (abis.contains(a)) return a;
  }
  return null;
}

/// Below zero when [a] is older than [b]; "v0.6.1" and "0.6.1+10002" are both 0.6.1.
int compareVersions(String a, String b) {
  List<int> nums(String v) =>
      RegExp(r'\d+')
          .allMatches(v.split(RegExp('[+-]')).first)
          .map((m) => int.parse(m[0]!))
          .toList();
  final x = nums(a), y = nums(b);
  for (var i = 0; i < max(x.length, y.length); i++) {
    final d = (i < x.length ? x[i] : 0) - (i < y.length ? y[i] : 0);
    if (d != 0) return d.sign;
  }
  return 0;
}

final _semver = RegExp(r'^v?\d+\.\d+\.\d+(?:[+-].*)?$');

/// True only when both are X.Y.Z (a v or +build is fine) and [current] is older.
bool isOlder(String current, String latest) =>
    _semver.hasMatch(current) &&
    _semver.hasMatch(latest) &&
    compareVersions(current, latest) < 0;

/// The latest release tag, like v0.6.1; null on any failure, which is never worth telling.
Future<String?> latestTag({HttpClient? http, Uri? url}) async {
  final client = http ?? HttpClient();
  client.userAgent = 'IlonaTV-Companion';
  try {
    final (status, body) = await _get(
      client,
      url ?? latestRelease,
      api: true,
    ).timeout(const Duration(seconds: 15));
    if (status != 200) return null;
    return (jsonDecode(body) as Map)['tag_name'] as String?;
  } catch (_) {
    return null;
  } finally {
    if (http == null) client.close(force: true);
  }
}

/// One GitHub call per launch: unauthenticated calls get 60 an hour per IP.
class UpdateCheck {
  UpdateCheck({required this.fetch, required this.own});

  final Future<String?> Function() fetch;
  final Future<String?> Function() own;

  late final Future<String?> latest = fetch().then(
    (v) => v,
    onError: (_) => null,
  );

  /// The newer release tag for the companion itself, or null.
  late final Future<String?> forApp = own().then(
    (v) => v == null ? null : newerThan(v),
    onError: (_) => null,
  );

  Future<String?> newerThan(String current) async {
    final l = await latest;
    return l != null && isOlder(current, l) ? l : null;
  }
}
