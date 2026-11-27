import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/main.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('a dark scheme on a near-black surface, seeded from the accent', () {
    final a = companionTheme(kDefaultAccent);
    final b = companionTheme(const Color(0xFFFF5EC7));
    expect(a.colorScheme.brightness, Brightness.dark);
    expect(a.colorScheme.surface, const Color(0xFF0F1115));
    expect(a.scaffoldBackgroundColor, const Color(0xFF0F1115));
    expect(a.colorScheme.primary, isNot(b.colorScheme.primary));
  });

  test('button labels keep Inter', () {
    final th = companionTheme(kDefaultAccent);
    for (final style in [
      th.filledButtonTheme.style,
      th.outlinedButtonTheme.style,
      th.textButtonTheme.style,
    ]) {
      expect(style!.textStyle!.resolve({})!.fontFamily, 'Inter');
    }
  });

  testWidgets('the app follows the accent', (t) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(() => accent.value = kDefaultAccent);
    await t.pumpWidget(CompanionApp(tvs: Tvs()));
    Color primary() =>
        Theme.of(t.element(find.byType(Scaffold).first)).colorScheme.primary;
    final before = primary();
    accent.value = const Color(0xFF34D07A);
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    expect(primary(), isNot(before));
    expect(
      primary(),
      companionTheme(const Color(0xFF34D07A)).colorScheme.primary,
    );
  });
}
