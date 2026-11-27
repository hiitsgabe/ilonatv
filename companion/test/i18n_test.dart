import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/main.dart';
import 'package:ilonatv_companion/tvs.dart';

void main() {
  tearDown(() => I18n.language = 'en');

  test('en and pt have the same keys, all with text', () {
    final keys = i18nKeys('en');
    expect(i18nKeys('pt'), keys);
    for (final language in ['en', 'pt']) {
      I18n.language = language;
      for (final key in keys) {
        expect(t(key), isNotEmpty, reason: '$language: $key');
      }
    }
  });

  test('on desktop no text calls the computer a phone', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    // Only seen on Android: the camera, the phone installer, the APK update.
    const androidOnly = {
      'scanHint',
      'cameraDenied',
      'instUseComputer',
      'instNeeds5555',
      'allowInstalls',
    };
    for (final (language, word) in [('en', 'phone'), ('pt', 'celular')]) {
      I18n.language = language;
      for (final key in i18nKeys(language)) {
        if (key.contains('@') || androidOnly.contains(key)) continue;
        expect(t(key).toLowerCase(), isNot(contains(word)), reason: key);
      }
    }
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    I18n.language = 'en';
    expect(t('tagline'), contains('phone'));
  });

  testWidgets('CompanionApp shows the app name', (tester) async {
    await tester.pumpWidget(CompanionApp(tvs: Tvs()));
    expect(find.text(t('appName')), findsOneWidget);
  });
}
