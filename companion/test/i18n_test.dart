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

  testWidgets('CompanionApp shows the app name', (tester) async {
    await tester.pumpWidget(CompanionApp(tvs: Tvs()));
    expect(find.text(t('appName')), findsOneWidget);
  });
}
