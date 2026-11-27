import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/about_sheet.dart';
import 'package:ilonatv_companion/ui/home_page.dart';
import 'package:ilonatv_protocol/releases.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// GitHub as the test wants it: [version] is the latest, or [fails].
class FakeReleases extends ReleaseSource {
  FakeReleases(this.version, {this.fails, this.fetchFails});

  final String? version;
  final Object? fails;
  final Object? fetchFails;
  final asked = <String>[];

  @override
  Future<ReleaseAsset?> named(String name) async {
    asked.add(name);
    if (fails case final e?) throw e;
    return ReleaseAsset(
      url: Uri.parse('https://example.com/$name'),
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
    return to;
  }
}

void main() {
  final calls = <MethodCall>[];
  var canInstall = true;

  setUp(() {
    I18n.language = 'en';
    calls.clear();
    canInstall = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('tv.ilona.companion/host'),
          (c) async {
            calls.add(c);
            return switch (c.method) {
              'appVersion' => '0.6.1',
              'cacheDir' => '/cache',
              'canInstall' => canInstall,
              'installApk' => 'aborted',
              _ => null,
            };
          },
        );
  });

  List<String> methods() => [for (final c in calls) c.method];

  Future<void> show(WidgetTester t, ReleaseSource r) async {
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AboutSheet(releases: r)),
      ),
    );
    await t.pumpAndSettle();
  }

  Future<void> tap(WidgetTester t, String text) async {
    await t.tap(find.text(text));
    await t.pumpAndSettle();
  }

  testWidgets('the home\'s About opens the sheet with the version', (t) async {
    SharedPreferences.setMockInitialValues({});
    await t.pumpWidget(
      MaterialApp(
        home: HomePage(
          tvs: Tvs(),
          clientFor: (_) => throw UnimplementedError(),
        ),
      ),
    );
    await t.tap(find.byTooltip(t0('about')));
    await t.pumpAndSettle();
    expect(find.byType(AboutSheet), findsOneWidget);
    expect(find.text('0.6.1'), findsOneWidget);
  });

  testWidgets('a check that finds nothing newer says so', (t) async {
    final r = FakeReleases('v0.6.1');
    await show(t, r);
    await tap(t, t0('checkUpdates'));
    expect(r.asked, ['ilonatv-companion.apk']);
    expect(find.text(t0('upToDate')), findsOneWidget);
    expect(find.text(t0('checkUpdates')), findsOneWidget);
  });

  testWidgets('a newer release downloads and goes to the system installer', (
    t,
  ) async {
    await show(t, FakeReleases('v0.7.0'));
    await tap(t, t0('checkUpdates'));
    await tap(t, t0('updateTo').replaceAll('{version}', 'v0.7.0'));
    final install = calls.singleWhere((c) => c.method == 'installApk');
    expect(install.arguments, {'path': '/cache/update.apk'});
    expect(
      find.text(t0('updateInstallFailed').replaceAll('{why}', 'aborted')),
      findsOneWidget,
    );
  });

  testWidgets('not allowed to install: the setting opens, nothing downloads', (
    t,
  ) async {
    canInstall = false;
    await show(t, FakeReleases('v0.7.0'));
    await tap(t, t0('checkUpdates'));
    await tap(t, t0('updateTo').replaceAll('{version}', 'v0.7.0'));
    expect(methods(), contains('allowInstalls'));
    expect(methods(), isNot(contains('installApk')));
    expect(find.text(t0('allowInstalls')), findsOneWidget);
  });

  testWidgets('a digest mismatch installs nothing and says why', (t) async {
    await show(t, FakeReleases('v0.7.0', fetchFails: const BadChecksum()));
    await tap(t, t0('checkUpdates'));
    await tap(t, t0('updateTo').replaceAll('{version}', 'v0.7.0'));
    expect(methods(), isNot(contains('installApk')));
    expect(find.text(t0('updateBadChecksum')), findsOneWidget);
  });

  testWidgets('a failed check says so and can be tried again', (t) async {
    await show(t, FakeReleases(null, fails: const SocketException('x')));
    await tap(t, t0('checkUpdates'));
    expect(find.text(t0('updateOffline')), findsOneWidget);
    expect(find.text(t0('checkUpdates')), findsOneWidget);
  });
}

String t0(String k) => t(k);
