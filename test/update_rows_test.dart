import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv/app.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/ui/update_rows.dart';
import 'package:ilonatv_protocol/releases.dart';

/// GitHub as the test wants it: [latest] answers, [fetch] fails with [fails].
class FakeReleases extends ReleaseSource {
  FakeReleases(this.version, {this.fails, this.fetchFails});

  final String? version;
  final Object? fails;
  final Object? fetchFails;
  final asked = <String>[];

  @override
  Future<ReleaseAsset?> latest(String abi) async {
    asked.add(abi);
    if (fails case final e?) throw e;
    return version == null
        ? null
        : ReleaseAsset(
            url: Uri.parse('https://example.com/ilonatv-$abi.apk'),
            size: 100,
            version: version!,
            sha256: '0' * 64,
          );
  }

  @override
  Future<File> fetch(
    ReleaseAsset a,
    File to, {
    void Function(int received, int total)? progress,
  }) async {
    progress?.call(50, 100);
    if (fetchFails case final e?) throw e;
    progress?.call(100, 100);
    return to;
  }
}

void main() {
  final calls = <MethodCall>[];
  var canInstall = true;
  String? installError = 'aborted';

  setUp(() {
    calls.clear();
    canInstall = true;
    installError = 'aborted';
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('tv.ilona/host'), (
          call,
        ) async {
          calls.add(call);
          return switch (call.method) {
            'abis' => 'armeabi-v7a,armeabi',
            'cacheDir' => '/cache',
            'canInstall' => canInstall,
            'installApk' => installError,
            'openSystemSettings' => true,
            _ => null,
          };
        });
  });

  List<String> methods() => [for (final c in calls) c.method];

  Future<void> show(WidgetTester tester, ReleaseSource r) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: UpdateRows(releases: r)),
      ),
    );
  }

  Future<void> press(WidgetTester tester, String text) async {
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('the version, then a check that finds nothing newer', (
    tester,
  ) async {
    final r = FakeReleases('v$kVersion');
    await show(tester, r);
    expect(find.text(kVersion), findsOneWidget);
    await press(tester, t('checkUpdates'));
    expect(r.asked, ['armeabi-v7a']);
    expect(find.text(t('checkUpdates')), findsOneWidget);
    expect(find.text(t('upToDate')), findsOneWidget);
  });

  testWidgets('a newer release: the row offers it and OK on the D-pad '
      'downloads, then installs', (tester) async {
    await show(tester, FakeReleases('v99.0.0'));
    await press(tester, t('checkUpdates'));
    final update = t('updateTo').replaceAll('{version}', 'v99.0.0');
    expect(find.text(update), findsOneWidget);
    Focus.of(tester.element(find.text(update))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    final install = calls.singleWhere((c) => c.method == 'installApk');
    expect(install.arguments, {'path': '/cache/ilonatv-armeabi-v7a.apk'});
    // Declined at the system's confirm: said so, and it can be pressed again.
    expect(
      find.text(t('updateInstallFailed').replaceAll('{why}', 'aborted')),
      findsOneWidget,
    );
    expect(find.text(update), findsOneWidget);
  });

  testWidgets('not allowed to install: the unknown-sources screen opens, '
      'with the Fire TV way there, and nothing downloads', (tester) async {
    canInstall = false;
    await show(tester, FakeReleases('v99.0.0'));
    await press(tester, t('checkUpdates'));
    await press(tester, t('updateTo').replaceAll('{version}', 'v99.0.0'));
    final open = calls.singleWhere((c) => c.method == 'openSystemSettings');
    expect(open.arguments, {
      'component': null,
      'action': 'android.settings.MANAGE_UNKNOWN_APP_SOURCES',
      'data': 'package:tv.ilona.app',
      'pause': true,
    });
    expect(find.text(t('allowInstalls')), findsOneWidget);
    expect(methods(), isNot(contains('installApk')));
  });

  testWidgets('a digest mismatch installs nothing and says why', (
    tester,
  ) async {
    await show(
      tester,
      FakeReleases('v99.0.0', fetchFails: const BadChecksum()),
    );
    await press(tester, t('checkUpdates'));
    await press(tester, t('updateTo').replaceAll('{version}', 'v99.0.0'));
    expect(methods(), isNot(contains('installApk')));
    expect(find.text(t('updateBadChecksum')), findsOneWidget);
  });

  for (final (error, key) in [
    (const SocketException('offline'), 'updateOffline'),
    (const RateLimited(), 'updateRateLimited'),
    (const NoAsset(), 'updateNoApk'),
  ]) {
    testWidgets('a check that fails with $error says $key', (tester) async {
      await show(tester, FakeReleases(null, fails: error));
      await press(tester, t('checkUpdates'));
      expect(find.text(t(key)), findsOneWidget);
      expect(find.text(t('checkUpdates')), findsOneWidget);
    });
  }
}
