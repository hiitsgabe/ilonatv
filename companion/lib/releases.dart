import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

final latestRelease = Uri.parse(
  'https://api.github.com/repos/hiitsgabe/ilonatv/releases/latest',
);
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

/// The latest release has no APK (or no checksum) for the TV's ABI.
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

  Future<File> fetch(
    ReleaseAsset a,
    File to, {
    void Function(int received, int total)? progress,
  }) => download(a, to, progress: progress);
}

/// Null when the repository has no release yet.
Future<ReleaseAsset?> latestTvApk(
  String abi, {
  HttpClient? http,
  Uri? url,
}) async {
  final client = http ?? HttpClient();
  client.userAgent = 'IlonaTV-Companion';
  try {
    return await _latest(
      client,
      abi,
      url ?? latestRelease,
    ).timeout(const Duration(seconds: 15));
  } finally {
    if (http == null) client.close(force: true);
  }
}

Future<ReleaseAsset?> _latest(HttpClient client, String abi, Uri url) async {
  final (status, body) = await _get(client, url, api: true);
  if (status == 404) return null;
  if (status == 403 || status == 429) throw const RateLimited();
  if (status != 200) throw HttpException('GitHub answered $status', uri: url);
  final release = jsonDecode(body) as Map<String, Object?>;
  final assets = (release['assets'] as List).cast<Map<String, Object?>>();
  Map<String, Object?>? named(String n) =>
      assets.where((a) => a['name'] == n).firstOrNull;
  final name = 'ilonatv-$abi.apk';
  final apk = named(name);
  if (apk == null) throw const NoAsset();
  final digest = apk['digest'] as String?;
  var sum = digest != null && digest.startsWith('sha256:')
      ? digest.substring(7)
      : null;
  final sums = named('SHA256SUMS');
  if (sum == null && sums != null) {
    final sumsUrl = Uri.parse(sums['browser_download_url'] as String);
    final (s, text) = await _get(client, sumsUrl);
    if (s != 200) throw HttpException('SHA256SUMS answered $s', uri: sumsUrl);
    sum = RegExp(
      '^([0-9a-fA-F]{64}) [ *]${RegExp.escape(name)}\$',
      multiLine: true,
    ).firstMatch(text)?.group(1);
  }
  if (sum == null) throw const NoAsset();
  return ReleaseAsset(
    url: Uri.parse(apk['browser_download_url'] as String),
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
