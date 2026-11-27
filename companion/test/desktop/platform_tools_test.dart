import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/desktop/platform_tools.dart';
import 'package:ilonatv_protocol/releases.dart';

import 'fake_process.dart';

const _repo = 'https://dl.google.com/android/repository/';

String manifest({String darwinUrl = 'platform-tools_r37.0.3-darwin.zip'}) =>
    '''
<sdk:sdk-repository>
  <remotePackage path="build-tools;37.0.0">
    <archives>
      <archive>
        <complete>
          <size>1</size>
          <checksum type="sha1">0000000000000000000000000000000000000000</checksum>
          <url>build-tools_r37-macosx.zip</url>
        </complete>
        <host-os>macosx</host-os>
      </archive>
    </archives>
  </remotePackage>
  <remotePackage path="platform-tools">
    <revision><major>37</major><minor>0</minor><micro>3</micro></revision>
    <archives>
      <archive>
        <complete>
          <size>9571024</size>
          <checksum type="sha1">e1579b288a7ae4e9bc28dedec6a154d78b3c04ed</checksum>
          <url>platform-tools_r37.0.3-linux.zip</url>
        </complete>
        <host-os>linux</host-os>
      </archive>
      <archive>
        <complete>
          <size>16597626</size>
          <checksum type="sha1">d48920e2650321710b4d15d3acd9e277d59cd55b</checksum>
          <url>$darwinUrl</url>
        </complete>
        <host-os>macosx</host-os>
      </archive>
      <archive>
        <complete>
          <size>8188601</size>
          <checksum type="sha1">7fea85bc18d0480bc81d3603952d666f49496e5a</checksum>
          <url>platform-tools_r37.0.3-win.zip</url>
        </complete>
        <host-os>windows</host-os>
      </archive>
    </archives>
  </remotePackage>
</sdk:sdk-repository>
''';

void main() {
  group('platformToolsArchive', () {
    test('picks platform-tools for the host OS, never another package', () {
      final mac = platformToolsArchive(manifest(), 'macosx', _repo)!;
      expect(mac.url.toString(), '${_repo}platform-tools_r37.0.3-darwin.zip');
      expect(mac.size, 16597626);
      expect(mac.sha1, 'd48920e2650321710b4d15d3acd9e277d59cd55b');
      final win = platformToolsArchive(manifest(), 'windows', _repo)!;
      expect(win.url.toString(), '${_repo}platform-tools_r37.0.3-win.zip');
      expect(win.sha1, '7fea85bc18d0480bc81d3603952d666f49496e5a');
    });

    test('an archive from anywhere but the repository is no archive', () {
      for (final url in [
        'https://evil.test/platform-tools.zip',
        'http://dl.google.com/android/repository/p.zip',
        '../../evil.zip',
      ]) {
        expect(
          platformToolsArchive(manifest(darwinUrl: url), 'macosx', _repo),
          isNull,
          reason: url,
        );
      }
    });

    test('no platform-tools, or none for the host, is null', () {
      expect(platformToolsArchive('<sdk/>', 'macosx', _repo), isNull);
      expect(platformToolsArchive(manifest(), 'solaris', _repo), isNull);
    });
  });

  group('download', () {
    late Directory dir;
    late HttpServer server;
    late List<int> zip;
    late String sum;
    late FakeProcesses procs;
    var redirect = false;

    // The fake ditto: what it unpacks into the folder it is given.
    void unpacks(void Function(String into) files) => procs.reply = (args) {
      files(args.last);
      return null;
    };

    setUp(() async {
      redirect = false;
      dir = Directory.systemTemp.createTempSync('pt');
      zip = List.generate(5000, (i) => i % 251);
      sum = '${sha1.convert(zip)}';
      procs = FakeProcesses();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) {
        final path = req.uri.path;
        if (redirect) {
          req.response.statusCode = HttpStatus.found;
          req.response.headers.set('location', '/elsewhere.xml');
        } else if (path.endsWith('.xml')) {
          req.response.write(
            manifest()
                .replaceAll('d48920e2650321710b4d15d3acd9e277d59cd55b', sum)
                .replaceAll('16597626', '${zip.length}'),
          );
        } else {
          req.response.add(zip);
        }
        req.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      dir.deleteSync(recursive: true);
    });

    PlatformTools tools() {
      final repo = 'http://127.0.0.1:${server.port}/';
      return PlatformTools(
        dir: dir.path,
        os: TargetPlatform.macOS,
        start: procs.start,
        env: const {},
        repository: repo,
        manifest: Uri.parse('${repo}repository2-4.xml'),
      );
    }

    test(
      'checks the SHA-1, then extracts with ditto, arguments apart',
      () async {
        File('${dir.path}/platform-tools/old').createSync(recursive: true);
        unpacks((into) {
          File('$into/platform-tools/adb').createSync(recursive: true);
          Link('$into/platform-tools/lib').createSync('adb');
        });
        final got = <int>[];
        await tools().download(progress: (n, _) => got.add(n));
        final z = '${dir.path}/platform-tools.zip';
        final cmd = procs.started.single;
        expect(cmd.take(4), ['/usr/bin/ditto', '-x', '-k', z]);
        expect(cmd.last, startsWith('${dir.path}/.extract-'));
        expect(cmd, hasLength(5));
        expect(got.last, zip.length);
        // The new copy replaced the old one, and nothing else is left.
        expect(File('${dir.path}/platform-tools/adb').existsSync(), isTrue);
        expect(File('${dir.path}/platform-tools/old').existsSync(), isFalse);
        expect(dir.listSync().map((e) => e.path), [
          '${dir.path}/platform-tools',
        ]);
      },
    );

    test('a SHA-1 mismatch refuses: nothing extracted, nothing kept', () async {
      zip = [...zip, 1];
      await expectLater(tools().download(), throwsA(isA<BadChecksum>()));
      expect(procs.started, isEmpty);
      expect(dir.listSync(), isEmpty);
    });

    test('an extract that leaves no adb fails', () async {
      procs.exitCode = 1;
      await expectLater(tools().download(), throwsA(isA<ProcessException>()));
      expect(Directory('${dir.path}/platform-tools').existsSync(), isFalse);
    });

    for (final (what, files) in [
      (
        'anything beside platform-tools',
        (String into) {
          File('$into/platform-tools/adb').createSync(recursive: true);
          File('$into/.profile').createSync();
        },
      ),
      (
        'a link out of the folder',
        (String into) {
          File('$into/platform-tools/adb').createSync(recursive: true);
          Link('$into/platform-tools/x').createSync('/etc');
        },
      ),
      (
        'a link up and out',
        (String into) {
          File('$into/platform-tools/adb').createSync(recursive: true);
          Link('$into/platform-tools/x').createSync('../../..');
        },
      ),
    ]) {
      test('$what is refused, and the current copy stays', () async {
        File('${dir.path}/platform-tools/adb').createSync(recursive: true);
        unpacks(files);
        await expectLater(tools().download(), throwsA(isA<ProcessException>()));
        expect(dir.listSync().map((e) => e.path), [
          '${dir.path}/platform-tools',
        ]);
        expect(File('${dir.path}/platform-tools/adb').existsSync(), isTrue);
      });
    }

    test('a redirect is not followed', () async {
      redirect = true;
      await expectLater(tools().download(), throwsA(isA<HttpException>()));
      expect(procs.started, isEmpty);
    });
  });

  test('Windows extracts with its own tar, macOS with ditto', () {
    final (tar, tarArgs) = extractCommand(
      'a.zip',
      'd',
      TargetPlatform.windows,
      r'C:\Windows',
    );
    expect(tar, r'C:\Windows\System32\tar.exe');
    expect(tarArgs, ['-xf', 'a.zip', '-C', 'd']);
    final (ditto, dittoArgs) = extractCommand(
      'a.zip',
      'd',
      TargetPlatform.macOS,
      '',
    );
    expect(ditto, '/usr/bin/ditto');
    expect(dittoArgs, ['-x', '-k', 'a.zip', 'd']);
  });

  test('adb on PATH comes before a downloaded one', () {
    final bin = Directory.systemTemp.createTempSync('bin');
    final own = Directory.systemTemp.createTempSync('own');
    addTearDown(() {
      bin.deleteSync(recursive: true);
      own.deleteSync(recursive: true);
    });
    File('${own.path}/platform-tools/adb').createSync(recursive: true);
    PlatformTools at(String path) => PlatformTools(
      dir: own.path,
      os: TargetPlatform.macOS,
      env: {'PATH': path, 'HOME': '/nonexistent'},
    );
    // A Homebrew adb on the machine running the tests is just as right.
    expect(
      at('/nonexistent:${bin.path}').adbPath(),
      anyOf(
        '${own.path}/platform-tools/adb',
        '/opt/homebrew/bin/adb',
        '/usr/local/bin/adb',
      ),
    );
    File('${bin.path}/adb').createSync();
    expect(at('/nonexistent:${bin.path}').adbPath(), '${bin.path}/adb');
  });

  test('PATH: only absolute directories, Windows quotes dropped', () {
    PlatformTools on(TargetPlatform os, String path) =>
        PlatformTools(dir: '/x', os: os, env: {'PATH': path});
    expect(on(TargetPlatform.macOS, '/usr/bin:bin:.::/opt/x').pathDirs(), [
      '/usr/bin',
      '/opt/x',
    ]);
    expect(
      on(
        TargetPlatform.windows,
        r'"C:\Program Files\adb";tools;C:\bin;;\\server\share;.\x',
      ).pathDirs(),
      [r'C:\Program Files\adb', r'C:\bin', r'\\server\share'],
    );
  });

  group('pairing needs platform-tools 30 or newer', () {
    late Directory bin, own;
    late FakeProcesses procs;
    setUp(() {
      bin = Directory.systemTemp.createTempSync('bin');
      own = Directory.systemTemp.createTempSync('own');
      File('${bin.path}/adb').createSync();
      procs = FakeProcesses();
    });
    tearDown(() {
      bin.deleteSync(recursive: true);
      own.deleteSync(recursive: true);
    });

    PlatformTools tools() => PlatformTools(
      dir: own.path,
      os: TargetPlatform.macOS,
      start: procs.start,
      env: {'PATH': bin.path},
    );

    void version(String v) => procs.reply = (_) => (
      0,
      'Android Debug Bridge version 1.0.41\nVersion $v\nInstalled as x\n',
    );

    test('a recent adb on PATH pairs', () async {
      version('35.0.2-12147458');
      expect(await tools().pairAdbPath(), '${bin.path}/adb');
      expect(procs.started.single, ['${bin.path}/adb', 'version']);
    });

    test('an old one gives way to the downloaded copy, or to none', () async {
      version('29.0.6-6198805');
      expect(await tools().pairAdbPath(), isNull);
      File('${own.path}/platform-tools/adb').createSync(recursive: true);
      expect(await tools().pairAdbPath(), '${own.path}/platform-tools/adb');
    });
  });
}
