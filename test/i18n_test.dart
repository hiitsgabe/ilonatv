import 'package:elimor/i18n.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => I18n.language = 'en');

  test('pt and en differ, unknown key echoes', () {
    I18n.language = 'en';
    final a = t('settings');
    expect(a, 'Settings');
    I18n.language = 'pt';
    expect(t('settings'), isNot(a));
    expect(t('nope'), 'nope');
  });

  test('unknown language falls back to English', () {
    I18n.language = 'xx';
    expect(t('settings'), 'Settings');
  });

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
}
