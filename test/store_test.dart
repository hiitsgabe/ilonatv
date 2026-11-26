import 'dart:io';
import 'dart:typed_data';

import 'package:elimor/store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('elimor'));
  tearDown(() => dir.delete(recursive: true));

  test('write, read, writtenAt, delete', () async {
    final s = Store(dir);
    expect(await s.read('x'), isNull);
    expect(await s.writtenAt('x'), isNull);

    await s.write('x', {'k': 1});
    expect(await s.read('x'), {'k': 1});
    expect(
      (await s.writtenAt('x'))!.difference(DateTime.now()).abs(),
      lessThan(const Duration(seconds: 5)),
    );
    // Only the entry: the temp file the write goes through is gone again.
    expect(
      Directory('${dir.path}/cache').listSync().single.path,
      endsWith('/x.json'),
    );

    await s.delete('x');
    expect(await s.read('x'), isNull);
    expect(await s.writtenAt('x'), isNull);
    await s.delete('x'); // already gone: a no-op, not an error
  });

  test('readBytes and writeBytes keep a file as is, under its own name', () async {
    final s = Store(dir);
    expect(await s.readBytes('icon-x.png'), isNull);
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 1, 2]);
    await s.writeBytes('icon-x.png', png);
    expect(await s.readBytes('icon-x.png'), png);
    expect(
      Directory('${dir.path}/cache').listSync().single.path,
      endsWith('/icon-x.png'),
    );
    // Over an old one, whole.
    await s.writeBytes('icon-x.png', Uint8List.fromList([1]));
    expect(await s.readBytes('icon-x.png'), [1]);
  });

  test('freshOrNull gives the entry only while it is young', () async {
    final s = Store(dir);
    const hour = Duration(hours: 1);
    expect(await s.freshOrNull('x', hour), isNull, reason: 'no such entry');

    await s.write('x', {'k': 1});
    final file = File('${dir.path}/cache/x.json');
    void age(Duration d) =>
        file.setLastModifiedSync(DateTime.now().subtract(d));

    expect(await s.freshOrNull('x', hour), {'k': 1}, reason: 'just written');
    age(const Duration(minutes: 59));
    expect(await s.freshOrNull('x', hour), {'k': 1}, reason: '59 minutes old');
    age(const Duration(minutes: 61));
    expect(await s.freshOrNull('x', hour), isNull, reason: '61 minutes old');
    // The entry itself is still there; it is only too old for this caller.
    expect(await s.read('x'), {'k': 1});
    age(const Duration(minutes: -5));
    expect(await s.freshOrNull('x', hour), isNull, reason: 'from the future');

    // A young file that is not an object reads as null, and goes, like read().
    file.writeAsStringSync('{');
    expect(await s.freshOrNull('x', hour), isNull, reason: 'cut short');
    expect(file.existsSync(), isFalse);
  });

  test('invalid json reads as null and is removed', () async {
    final s = Store(dir);
    for (final bad in ['{', '[1]']) {
      await s.write('x', {});
      final file = File('${dir.path}/cache/x.json')..writeAsStringSync(bad);

      expect(await s.read('x'), isNull, reason: bad);
      expect(file.existsSync(), isFalse, reason: bad);
    }
  });

  test(
    'a file cut inside a multibyte character reads as null and is removed',
    () async {
      final s = Store(dir);
      await s.write('x', {}); // makes the cache directory
      // The bytes of {"t":"a followed by 0xc3, the first byte of a two-byte
      // character.
      final file = File('${dir.path}/cache/x.json')
        ..writeAsBytesSync([0x7b, 0x22, 0x74, 0x22, 0x3a, 0x22, 0x61, 0xc3]);

      expect(await s.read('x'), isNull);
      expect(file.existsSync(), isFalse);
    },
  );

  test(
    'a read that overlaps a write sees the old entry or the new one',
    () async {
      final s = Store(dir);
      final pad = 'x' * 100000; // big enough that a write takes several steps
      await s.write('x', {'n': 0, 'pad': pad});

      for (var n = 1; n <= 20; n++) {
        final write = s.write('x', {'n': n, 'pad': pad});
        final reads = [for (var i = 0; i < 5; i++) s.read('x')];
        for (final read in await Future.wait(reads)) {
          expect(
            read,
            isNotNull,
            reason: 'a read next to write $n found no entry',
          );
        }
        await write;
      }
      expect((await s.read('x'))!['n'], 20);
    },
  );

  test('concurrent writes of one name leave one complete entry', () async {
    final s = Store(dir);
    final pad = 'x' * 100000;
    await Future.wait([
      for (var n = 0; n < 10; n++) s.write('x', {'n': n, 'pad': pad}),
    ]);

    expect((await s.read('x'))!['pad'], pad);
    expect(Directory('${dir.path}/cache').listSync(), hasLength(1));
  });
}
