import 'package:elimor/companion/pairing.dart';
import 'package:elimor/i18n.dart';
import 'package:elimor/settings.dart';
import 'package:elimor/ui/companion_pane.dart';
import 'package:elimor/ui/qr_code.dart';
import 'package:elimor/ui/settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Pairing> _pump(WidgetTester tester, String? address) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final s = await Settings.load();
  s.companionDevices['tok'] = 'Pixel 9';
  final pairing = Pairing(s);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: CompanionPane(pairing, address)),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return pairing;
}

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(SettingsRow));

void main() {
  testWidgets('shows the QR of the address and secret, and the code, offered '
      'while shown', (tester) async {
    final pairing = await _pump(tester, '192.168.1.5');
    expect(find.text(pairing.code), findsOneWidget);
    expect(
      tester.widget<QrCode>(find.byType(QrCode)).data,
      'http://192.168.1.5:8642/#s=${pairing.secret}',
    );
    expect(find.text(t('companionHelp')), findsOneWidget);
    expect(pairing.codeOffered, isTrue);
    await tester.pumpWidget(const SizedBox());
    expect(pairing.codeOffered, isFalse);
  });

  testWidgets('off the network, only the code', (tester) async {
    final pairing = await _pump(tester, null);
    expect(find.byType(QrCode), findsNothing);
    expect(find.text(pairing.code), findsOneWidget);
    expect(find.text(t('noNetwork')), findsOneWidget);
  });

  testWidgets('a paired device has Remove, which unpairs it', (tester) async {
    final pairing = await _pump(tester, '192.168.1.5');
    expect(_row('Pixel 9'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: _row('Pixel 9'),
        matching: find.byIcon(Icons.delete_outline),
      ),
    );
    await tester.pumpAndSettle();
    expect(pairing.settings.companionDevices, isEmpty);
    expect(_row('Pixel 9'), findsNothing);
  });

  testWidgets('New QR changes the secret and keeps the devices', (
    tester,
  ) async {
    final pairing = await _pump(tester, '192.168.1.5');
    final before = pairing.secret;
    await tester.tap(_row(t('newQr')));
    await tester.pumpAndSettle();
    expect(pairing.secret, isNot(before));
    expect(
      tester.widget<QrCode>(find.byType(QrCode)).data,
      'http://192.168.1.5:8642/#s=${pairing.secret}',
    );
    expect(pairing.settings.companionDevices, {'tok': 'Pixel 9'});
  });
}
