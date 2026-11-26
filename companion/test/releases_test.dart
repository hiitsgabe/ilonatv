import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/releases.dart';

void main() {
  late HttpServer server;
  late Uri base;
  late Directory dir;
  final apk = utf8.encode('not really an apk');
  final apkSum = sha256.convert(apk).toString();
  int status = 200;
  Map<String, Object?> release = {};
  final requests = <HttpHeaders>[];

  Map<String, Object?> asset(String name, {String? digest}) => {
    'name': name,
    'size': apk.length,
    'browser_download_url': '$base/dl/$name',
    'digest': ?digest,
  };

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('releases_test');
    requests.clear();
    status = 200;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    base = Uri.parse('http://127.0.0.1:${server.port}');
    release = {
      'tag_name': 'v0.6.1',
      'assets': [
        asset('ilonatv-arm64-v8a.apk', digest: 'sha256:$apkSum'),
        asset('ilonatv-armeabi-v7a.apk', digest: 'sha256:$apkSum'),
      ],
    };
    server.listen((r) {
      requests.add(r.headers);
      final res = r.response;
      if (r.uri.path == '/latest') {
        res.statusCode = status;
        res.write(jsonEncode(release));
      } else if (r.uri.path == '/moved') {
        res.redirect(base.resolve('/dl/ilonatv-arm64-v8a.apk'));
        return;
      } else if (r.uri.path == '/stall') {
        res.add(apk.sublist(0, 4));
        res.flush();
        return;
      } else if (r.uri.path == '/dl/SHA256SUMS') {
        res.write('${'0' * 64}  ilonatv-armeabi-v7a.apk\n');
        res.write('$apkSum  ilonatv-arm64-v8a.apk\n');
      } else if (r.uri.path.startsWith('/dl/')) {
        res.add(apk);
      } else {
        res.statusCode = 404;
      }
      res.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    dir.deleteSync(recursive: true);
  });

  Future<ReleaseAsset?> latest(String abi) =>
      latestTvApk(abi, url: base.resolve('/latest'));

  test('latest picks the ABI asset with its digest', () async {
    final a = (await latest('arm64-v8a'))!;
    expect(a.url, base.resolve('/dl/ilonatv-arm64-v8a.apk'));
    expect(a.size, apk.length);
    expect(a.version, 'v0.6.1');
    expect(a.sha256, apkSum);
    expect(requests.single.value('accept'), 'application/vnd.github+json');
    expect(requests.single.value('user-agent'), 'IlonaTV-Companion');
  });

  test('without a digest, the sum comes from SHA256SUMS', () async {
    release['assets'] = [asset('ilonatv-arm64-v8a.apk'), asset('SHA256SUMS')];
    expect((await latest('arm64-v8a'))!.sha256, apkSum);
  });

  test('no release yet is null', () async {
    status = 404;
    expect(await latest('arm64-v8a'), isNull);
  });

  test('a release without the ABI asset throws NoAsset', () async {
    release['assets'] = [asset('ilonatv-arm64-v8a.apk', digest: 'x')];
    await expectLater(latest('armeabi-v7a'), throwsA(isA<NoAsset>()));
  });

  test('another status throws', () async {
    status = 500;
    await expectLater(latest('arm64-v8a'), throwsA(isA<HttpException>()));
  });

  for (final code in [403, 429]) {
    test('$code is GitHub limiting requests', () async {
      status = code;
      await expectLater(latest('arm64-v8a'), throwsA(isA<RateLimited>()));
    });
  }

  ReleaseAsset at(String path) => ReleaseAsset(
    url: base.resolve(path),
    size: apk.length,
    version: 'v0.6.1',
    sha256: apkSum,
  );

  test('download follows a redirect', () async {
    final f = await download(at('/moved'), File('${dir.path}/a.apk'));
    expect(f.readAsBytesSync(), apk);
  });

  test('a download that stalls times out and deletes the file', () async {
    final to = File('${dir.path}/a.apk');
    await expectLater(
      download(at('/stall'), to, stall: const Duration(milliseconds: 200)),
      throwsA(isA<TimeoutException>()),
    );
    expect(to.existsSync(), isFalse);
  });

  test('download writes the file and reports progress', () async {
    final a = (await latest('arm64-v8a'))!;
    final seen = <(int, int)>[];
    final f = await download(
      a,
      File('${dir.path}/a.apk'),
      progress: (got, total) => seen.add((got, total)),
    );
    expect(f.readAsBytesSync(), apk);
    expect(seen.last, (apk.length, apk.length));
  });

  test('a checksum mismatch deletes the file and throws', () async {
    final a = (await latest('arm64-v8a'))!;
    final bad = ReleaseAsset(
      url: a.url,
      size: a.size,
      version: a.version,
      sha256: '0' * 64,
    );
    final to = File('${dir.path}/a.apk');
    await expectLater(download(bad, to), throwsA(isA<BadChecksum>()));
    expect(to.existsSync(), isFalse);
  });

  test('versions compare by number, with or without the v', () {
    expect(compareVersions('0.6.0', 'v0.6.1'), -1);
    expect(compareVersions('0.6.1', 'v0.6.1'), 0);
    expect(compareVersions('0.10.0', 'v0.9.9'), 1);
    expect(compareVersions('1.0', 'v1.0.0'), 0);
    expect(compareVersions('0.6.1+10002', 'v0.6.1'), 0);
  });
}
