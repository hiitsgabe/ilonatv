import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The disk cache: one JSON object per name, in `<dir>/cache/<name>.json`. How
/// old an entry is comes from its file ([writtenAt]).
class Store {
  final Directory _dir;
  int _seq = 0;

  Store(Directory dir) : _dir = Directory('${dir.path}/cache');

  File _file(String name) => File('${_dir.path}/$name.json');

  /// Null when there is no such entry. A file that is not a JSON object (cut
  /// short, or damaged on disk) is deleted and reads as null too.
  Future<Map<String, dynamic>?> read(String name) async {
    Object? json;
    try {
      // The bytes are decoded here, and malformed ones kept (as U+FFFD): a file
      // cut inside a multibyte character then fails as JSON, like any other cut
      // file. readAsString() throws a FileSystemException for it, which would
      // leave the file in place.
      json = jsonDecode(
        utf8.decode(await _file(name).readAsBytes(), allowMalformed: true),
      );
    } on PathNotFoundException {
      return null;
    } on FormatException {
      // Dropped below, with the files that parse but are not an object.
    }
    if (json is Map<String, dynamic>) return json;
    await delete(name);
    return null;
  }

  /// Written to a temp file next to the entry and renamed over it, so a read
  /// sees the old entry or the new one, never half of one. Each write has a
  /// temp file of its own: writers of one name must not share one.
  Future<void> write(String name, Map<String, dynamic> json) async {
    await _dir.create(recursive: true);
    // ponytail: a crash, or a full disk, between the temp write and the rename
    // leaves a stray `<name>.json.N.tmp`. Nothing reads it and a later write
    // may reuse its name; sweep the directory at startup if they ever pile up.
    final temp = File('${_dir.path}/$name.json.${_seq++}.tmp');
    await temp.writeAsString(jsonEncode(json));
    await temp.rename(_file(name).path);
  }

  /// Bytes kept under [name] (`<dir>/cache/<name>`, a PNG say) with
  /// [writeBytes]; null when there is no such file.
  Future<Uint8List?> readBytes(String name) async {
    try {
      return await File('${_dir.path}/$name').readAsBytes();
    } on FileSystemException {
      return null;
    }
  }

  /// [bytes] under [name], through a temp file and a rename like [write].
  Future<void> writeBytes(String name, Uint8List bytes) async {
    await _dir.create(recursive: true);
    final temp = File('${_dir.path}/$name.${_seq++}.tmp');
    await temp.writeAsBytes(bytes);
    await temp.rename('${_dir.path}/$name');
  }

  Future<DateTime?> writtenAt(String name) async {
    try {
      return await _file(name).lastModified();
    } on PathNotFoundException {
      return null;
    }
  }

  /// The entry, but only if it was written less than [maxAge] ago; null if it
  /// is older, is missing or cannot be read. A file from the future (the clock
  /// was off) is not young either.
  Future<Map<String, dynamic>?> freshOrNull(
    String name,
    Duration maxAge,
  ) async {
    final at = await writtenAt(name);
    if (at == null) return null;
    final age = DateTime.now().difference(at);
    return !age.isNegative && age < maxAge ? read(name) : null;
  }

  /// Deleting what is not there is fine.
  Future<void> delete(String name) async {
    try {
      await _file(name).delete();
    } on PathNotFoundException {
      // Already gone.
    }
  }
}
