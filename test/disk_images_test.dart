import 'dart:io';
import 'dart:typed_data';

import 'package:elimor/disk_images.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  final fetched = <Uri>[];

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('elimor-img');
    DiskImages.dir = dir;
    fetched.clear();
    DiskImages.fetch = (uri, {timeout = const Duration(seconds: 15)}) async {
      fetched.add(uri);
      return Uint8List.fromList(uri.path.codeUnits);
    };
  });
  tearDown(() async {
    DiskImages.dir = null;
    await dir.delete(recursive: true);
  });

  test('a picture is fetched once and read from disk after', () async {
    final a = Uri.parse('https://x/p/a.jpg');
    expect(await DiskImages.bytes(a), '/p/a.jpg'.codeUnits);
    // The write is not awaited by the caller.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await DiskImages.bytes(a), '/p/a.jpg'.codeUnits);
    expect(fetched, [a]);
    // Two thumbs of one file name are two files.
    final b = Uri.parse('https://x/q/a.jpg');
    expect(await DiskImages.bytes(b), '/q/a.jpg'.codeUnits);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(dir.listSync().whereType<File>(), hasLength(2));
    expect(await DiskImages.bytes(a), '/p/a.jpg'.codeUnits);
    expect(fetched, [a, b]);
  });

  test('without a dir every call fetches', () async {
    DiskImages.dir = null;
    final a = Uri.parse('https://x/a.jpg');
    await DiskImages.bytes(a);
    await DiskImages.bytes(a);
    expect(fetched, [a, a]);
  });

  test('prune drops the oldest files until under the ceiling', () async {
    for (final (i, name) in ['old', 'mid', 'new'].indexed) {
      final f = File('${dir.path}/$name')
        ..writeAsBytesSync(Uint8List(DiskImages.maxBytes ~/ 2));
      f.setLastModifiedSync(DateTime.now().subtract(Duration(hours: 3 - i)));
    }
    await DiskImages.prune();
    expect(
      dir.listSync().map((f) => f.path.split('/').last).toList()..sort(),
      ['mid', 'new'],
    );
  });

  test('DiskImage providers are equal by URL', () {
    expect(const DiskImage('https://x/a.jpg'), const DiskImage('https://x/a.jpg'));
    expect(
      const DiskImage('https://x/a.jpg').hashCode,
      const DiskImage('https://x/a.jpg').hashCode,
    );
    expect(
      const DiskImage('https://x/a.jpg'),
      isNot(const DiskImage('https://x/b.jpg')),
    );
  });
}
