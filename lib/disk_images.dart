import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'net.dart';

/// Pictures by URL, kept on disk under [dir]: posters, thumbs, logos and
/// backdrops come back from it on a cold start and when [imageCache] has let
/// them go, instead of being downloaded again. [bytes] is the fetch; a
/// [DiskImage] is the provider the widgets use.
class DiskImages {
  /// Set at start (`<files>/cache/img`); null (tests) means no disk and every
  /// call fetches.
  static Directory? dir;

  /// The network; tests hand in their own.
  @visibleForTesting
  static var fetch = getBytes;

  /// The disk cache's ceiling; [prune] drops the oldest files past it.
  static const maxBytes = 64 << 20;

  /// The file for [uri]: its hash and its file name, so two pictures of one
  /// name (every YouTube thumb is `hqdefault.jpg`) still get their own file.
  static File? _file(Uri uri) {
    final d = dir;
    if (d == null) return null;
    final name = uri.pathSegments.lastOrNull ?? '';
    return File('${d.path}/${uri.toString().hashCode.toRadixString(16)}-$name');
  }

  /// The picture at [uri]: from disk when it is there, else fetched and kept.
  /// A disk that will not write changes nothing.
  static Future<Uint8List> bytes(
    Uri uri, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    final file = _file(uri);
    if (file != null) {
      try {
        return await file.readAsBytes();
      } on FileSystemException {
        // Not there yet.
      }
    }
    final data = await fetch(uri, timeout: timeout);
    if (file != null) _write(file, data).ignore();
    return data;
  }

  // Through a temp file and a rename, like Store: a read sees a whole file or
  // none.
  static Future<void> _write(File file, Uint8List data) async {
    try {
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsBytes(data);
      await temp.rename(file.path);
    } catch (_) {}
  }

  /// Drops the oldest files until the cache is under [maxBytes]. Run once
  /// after start; nothing to do without a [dir].
  static Future<void> prune() async {
    final d = dir;
    if (d == null) return;
    try {
      final files = [
        for (final f in await d.list().toList())
          if (f is File) (f, await f.stat()),
      ];
      var total = files.fold(0, (n, e) => n + e.$2.size);
      files.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (f, s) in files) {
        if (total <= maxBytes) break;
        await f.delete();
        total -= s.size;
      }
    } catch (_) {}
  }
}

/// The picture at [url], through [DiskImages]. Equal by URL, so [imageCache]
/// keeps one decode per picture, as with `Image.network`.
class DiskImage extends ImageProvider<DiskImage> {
  final String url;
  const DiskImage(this.url);

  @override
  Future<DiskImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(DiskImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(
        codec: _load(decode),
        scale: 1,
        debugLabel: url,
      );

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final bytes = await DiskImages.bytes(Uri.parse(url));
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is DiskImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
