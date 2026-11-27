import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/desktop/host.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/version.dart';

import 'fake_process.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('only macOS and Windows are the desktop app', () {
    for (final (os, desktop) in [
      (TargetPlatform.macOS, true),
      (TargetPlatform.windows, true),
      (TargetPlatform.android, false),
      (TargetPlatform.linux, false),
      (TargetPlatform.iOS, false),
    ]) {
      debugDefaultTargetPlatformOverride = os;
      expect(isDesktop, desktop, reason: '$os');
    }
  });

  test('the URL is its own argument, never part of a command line', () {
    const url = 'https://example.test/a?b=1&c=2;rm -rf "x"';
    final (mac, macArgs) = openUrlCommand(url, TargetPlatform.macOS)!;
    expect(mac, '/usr/bin/open');
    expect(macArgs, [url]);
    final (exe, args) = openUrlCommand(url, TargetPlatform.windows)!;
    expect(exe, endsWith(r'\System32\rundll32.exe'));
    expect(args, ['url.dll,FileProtocolHandler', url]);
  });

  test('anything but https is not opened', () {
    for (final url in ['file:///etc/passwd', 'http://x.test', 'cmd', '']) {
      expect(openUrlCommand(url, TargetPlatform.macOS), isNull, reason: url);
    }
  });

  test('openUrl on desktop starts the browser command', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final procs = FakeProcesses();
    expect(
      await openUrlOnDesktop('https://example.test/r', start: procs.start),
      isTrue,
    );
    expect(procs.started.single, ['/usr/bin/open', 'https://example.test/r']);
    procs.exitCode = 1;
    expect(
      await openUrlOnDesktop('https://example.test/r', start: procs.start),
      isFalse,
    );
    expect(
      await openUrlOnDesktop('javascript:alert(1)', start: procs.start),
      isFalse,
    );
    expect(procs.started, hasLength(2));
  });

  test('desktop answers its version and volume without the channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    expect(await appVersion(), kVersion);
    await hardwareVolume(true);
    expect(await deviceName(), isNotEmpty);
  });
}
