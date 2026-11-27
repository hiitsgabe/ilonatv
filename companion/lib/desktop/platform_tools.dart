import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:ilonatv_protocol/releases.dart' show BadChecksum, NoAsset;

import 'host.dart';

const platformToolsTerms =
    'https://developer.android.com/studio/releases/platform-tools';
const sdkRepository = 'https://dl.google.com/android/repository/';
// The newest of Google's SDK repository manifests (repository2-5.xml does not exist yet).
final sdkManifest = Uri.parse('${sdkRepository}repository2-4.xml');

typedef Archive = ({Uri url, int size, String sha1});

/// The platform-tools archive for [hostOs] (macosx, windows) in Google's SDK
/// repository manifest; null when there is none, or it would come from
/// anywhere but [repository].
Archive? platformToolsArchive(String xml, String hostOs, String repository) {
  final pkg = RegExp(
    r'<remotePackage path="platform-tools">([\s\S]*?)</remotePackage>',
  ).firstMatch(xml)?.group(1);
  if (pkg == null) return null;
  for (final a in RegExp(r'<archive>([\s\S]*?)</archive>').allMatches(pkg)) {
    final body = a.group(1)!;
    String? tag(String re) => RegExp(re).firstMatch(body)?.group(1)?.trim();
    if (tag(r'<host-os>([^<]*)</host-os>') != hostOs) continue;
    final sha = tag(r'<checksum type="sha1">([0-9a-fA-F]{40})</checksum>');
    final size = int.tryParse(tag(r'<size>(\d+)</size>') ?? '');
    final path = tag(r'<url>([^<]*)</url>');
    if (sha == null || size == null || path == null) return null;
    final url = Uri.parse(repository).resolve(path);
    if (!'$url'.startsWith(repository) || '$url'.contains('/../')) {
      return null;
    }
    return (url: url, size: size, sha1: sha.toLowerCase());
  }
  return null;
}

/// How [zip] is unpacked into [dir] with what the OS ships, no unzip library.
(String, List<String>) extractCommand(
  String zip,
  String dir,
  TargetPlatform os,
  String systemRoot,
) => os == TargetPlatform.windows
    ? ('$systemRoot\\System32\\tar.exe', ['-xf', zip, '-C', dir])
    : ('/usr/bin/ditto', ['-x', '-k', zip, dir]);

/// Google's adb, never bundled (its licence forbids passing it on): the one
/// already on this computer, or platform-tools downloaded into [dir] once
/// the person agreed to Google's terms.
class PlatformTools {
  PlatformTools({
    String? dir,
    TargetPlatform? os,
    this.start = startProcess,
    Map<String, String>? env,
    this.repository = sdkRepository,
    Uri? manifest,
  }) : dir = dir ?? supportDir(),
       os = os ?? defaultTargetPlatform,
       env = env ?? Platform.environment,
       manifest = manifest ?? sdkManifest;

  final String dir;
  final TargetPlatform os;
  final StartProcess start;
  final Map<String, String> env;
  final String repository;
  final Uri manifest;

  bool get _windows => os == TargetPlatform.windows;
  String get _sep => _windows ? r'\' : '/';
  String get _exe => _windows ? 'adb.exe' : 'adb';

  String get downloaded => '$dir${_sep}platform-tools$_sep$_exe';

  /// PATH's directories, only absolute ones: a relative entry would run
  /// whatever adb sits in the current directory. Windows may quote them.
  @visibleForTesting
  List<String> pathDirs() => [
    for (final raw in (env['PATH'] ?? '').split(_windows ? ';' : ':'))
      ?_absolute(_windows ? raw.replaceAll('"', '') : raw),
  ];

  String? _absolute(String d) =>
      (_windows
          ? RegExp(r'^([A-Za-z]:\\|\\\\)').hasMatch(d)
          : d.startsWith('/'))
      ? d
      : null;

  /// The adb to run: PATH first, then where Android Studio or Homebrew put
  /// it (a Finder-launched app gets no shell PATH), then the downloaded one.
  String? adbPath() {
    final home = env['HOME'], local = env['LOCALAPPDATA'];
    final candidates = [
      for (final d in pathDirs()) '$d$_sep$_exe',
      if (!_windows && home != null)
        '$home/Library/Android/sdk/platform-tools/adb',
      if (!_windows) ...['/opt/homebrew/bin/adb', '/usr/local/bin/adb'],
      if (_windows && local != null)
        '$local\\Android\\Sdk\\platform-tools\\adb.exe',
      downloaded,
    ];
    return candidates.where((p) => File(p).existsSync()).firstOrNull;
  }

  /// An adb that has `pair` (platform-tools 30 or newer): the one found if it
  /// does, else the downloaded one; null when neither.
  Future<String?> pairAdbPath() async {
    final found = adbPath();
    if (found == null || found == downloaded) return found;
    if ((await _major(found) ?? 0) >= 30) return found;
    return File(downloaded).existsSync() ? downloaded : null;
  }

  // `adb version` prints "Version 35.0.2-12147458" on its second line.
  Future<int?> _major(String exe) async {
    try {
      final p = await start(exe, ['version']);
      final out = p.stdout.transform(utf8.decoder).join();
      p.stderr.drain<void>();
      await p.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () {
          p.kill();
          return -1;
        },
      );
      final text = await out.timeout(
        const Duration(seconds: 1),
        onTimeout: () => '',
      );
      final m = RegExp(r'^Version (\d+)\.', multiLine: true).firstMatch(text);
      return int.tryParse(m?.group(1) ?? '');
    } on ProcessException {
      return null;
    }
  }

  /// Fetches the manifest, then the archive it names for this OS, checks the
  /// archive's SHA-1 before anything is unpacked, and unpacks platform-tools
  /// into [dir]. Throws [BadChecksum] on a mismatch, [NoAsset] when the
  /// manifest has no archive for this OS.
  Future<void> download({void Function(int got, int total)? progress}) async {
    final http = HttpClient()..userAgent = 'IlonaTV-Companion';
    final zip = File('$dir${_sep}platform-tools.zip');
    try {
      final xml = await _get(
        http,
        manifest,
        (s) => s.transform(utf8.decoder).join(),
      );
      final a = platformToolsArchive(
        xml,
        _windows ? 'windows' : 'macosx',
        repository,
      );
      if (a == null) throw const NoAsset();
      await Directory(dir).create(recursive: true);
      final digest = await _get(http, a.url, (s) async {
        final sink = zip.openWrite();
        Digest? d;
        final hash = sha1.startChunkedConversion(
          ChunkedConversionSink<Digest>.withCallback((r) => d = r.single),
        );
        var got = 0;
        try {
          await for (final chunk in s) {
            hash.add(chunk);
            sink.add(chunk);
            got += chunk.length;
            progress?.call(got, a.size);
          }
        } finally {
          await sink.close();
        }
        hash.close();
        return '$d';
      });
      if (digest != a.sha1) throw const BadChecksum();
      await _install(zip);
    } finally {
      http.close(force: true);
      if (zip.existsSync()) zip.deleteSync();
    }
  }

  /// Unpacks [zip] beside the current copy, checks it holds platform-tools
  /// and nothing else, then swaps it in; a failure keeps the current copy.
  Future<void> _install(File zip) async {
    final stamp = DateTime.now().microsecondsSinceEpoch;
    final tmp = Directory('$dir$_sep.extract-$stamp');
    try {
      await tmp.create();
      final (exe, args) = extractCommand(
        zip.path,
        tmp.path,
        os,
        env['SystemRoot'] ?? r'C:\Windows',
      );
      final p = await start(exe, args);
      p.stdout.drain<void>();
      p.stderr.drain<void>();
      final code = await p.exitCode.timeout(const Duration(minutes: 2));
      final fresh = Directory('${tmp.path}${_sep}platform-tools');
      final top = tmp.listSync(followLinks: false);
      if (code != 0 ||
          top.length != 1 ||
          top.single is! Directory ||
          top.single.path != fresh.path ||
          !File('${fresh.path}$_sep$_exe').existsSync() ||
          _escapes(fresh)) {
        throw ProcessException(exe, args, 'extract failed', code);
      }
      final current = Directory('$dir${_sep}platform-tools');
      final old = current.existsSync()
          ? current.renameSync('$dir$_sep.old-$stamp')
          : null;
      try {
        fresh.renameSync(current.path);
      } catch (_) {
        old?.renameSync(current.path);
        rethrow;
      }
      try {
        old?.deleteSync(recursive: true);
      } on FileSystemException {
        // Windows keeps a running adb.exe's folder; it goes next time.
      }
    } finally {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    }
  }

  // A link whose target is outside the folder, or missing, is not Google's archive.
  bool _escapes(Directory d) {
    final root = d.resolveSymbolicLinksSync();
    for (final e in d.listSync(recursive: true, followLinks: false)) {
      if (e is! Link) continue;
      try {
        if (!e.resolveSymbolicLinksSync().startsWith('$root$_sep')) return true;
      } on FileSystemException {
        return true;
      }
    }
    return false;
  }

  static const _stall = Duration(seconds: 30);

  Future<T> _get<T>(
    HttpClient http,
    Uri url,
    Future<T> Function(Stream<List<int>>) read,
  ) async {
    final req = await http.getUrl(url).timeout(_stall);
    // Only what the manifest names, from where it names it: a redirect is a failure.
    req.followRedirects = false;
    final res = await req.close().timeout(_stall);
    if (res.statusCode != 200) {
      throw HttpException('answered ${res.statusCode}', uri: url);
    }
    return read(res.timeout(_stall));
  }
}
