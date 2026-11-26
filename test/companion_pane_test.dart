import 'package:ilonatv/companion/pairing.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/ui/companion_pane.dart';
import 'package:ilonatv/ui/qr_code.dart';
import 'package:ilonatv/ui/settings_kit.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<Pairing> _pump(
  WidgetTester tester,
  String? address, {
  Map<String, String> devices = const {'tok': 'Pixel 9'},
}) async {
  tester.view
    ..physicalSize = const Size(1920, 1080)
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues({});
  final s = await Settings.load();
  s.companionDevices.addAll(devices);
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

String? _focusedRow() =>
    primaryFocus?.context?.findAncestorWidgetOfExactType<SettingsRow>()?.title;

/// Remove on [device]'s row, from the remote: focus it, then OK.
Future<void> _remove(WidgetTester tester, String device) async {
  Focus.of(
    tester.element(
      find.descendant(
        of: _row(device),
        matching: find.byIcon(Icons.delete_outline),
      ),
    ),
  ).requestFocus();
  await tester.pump();
  await _ok(tester);
}

Future<void> _ok(WidgetTester tester) async {
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pumpAndSettle();
}

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

  testWidgets('after Remove, focus lands on the next device, then New QR; '
      'OK there removes nothing', (tester) async {
    final pairing = await _pump(
      tester,
      '192.168.1.5',
      devices: {'tok': 'Pixel 9', 'tok2': 'iPhone', 'tok3': 'iPad'},
    );
    final devices = pairing.settings.companionDevices;
    await _remove(tester, 'Pixel 9');
    expect(devices.values, ['iPhone', 'iPad']);
    expect(_focusedRow(), 'iPhone');
    await _ok(tester);
    expect(devices.values, ['iPhone', 'iPad']);
    await _remove(tester, 'iPad');
    expect(_focusedRow(), 'iPhone');
    await _remove(tester, 'iPhone');
    expect(devices, isEmpty);
    expect(_focusedRow(), t('newQr'));
  });

  testWidgets('a quick second OK on Remove removes one device and nothing '
      'breaks', (tester) async {
    final pairing = await _pump(
      tester,
      '192.168.1.5',
      devices: {'tok': 'Pixel 9', 'tok2': 'iPhone', 'tok3': 'iPad'},
    );
    Focus.of(
      tester.element(
        find.descendant(
          of: _row('Pixel 9'),
          matching: find.byIcon(Icons.delete_outline),
        ),
      ),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(pairing.settings.companionDevices.values, ['iPhone', 'iPad']);
  });

  testWidgets('leaving IlonaTv withdraws the code; coming back offers it', (
    tester,
  ) async {
    final pairing = await _pump(tester, '192.168.1.5');
    void go(List<AppLifecycleState> states) {
      for (final s in states) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
    }

    go(const [
      AppLifecycleState.inactive,
      AppLifecycleState.hidden,
      AppLifecycleState.paused,
    ]);
    expect(pairing.codeOffered, isFalse);
    go(const [
      AppLifecycleState.hidden,
      AppLifecycleState.inactive,
      AppLifecycleState.resumed,
    ]);
    expect(pairing.codeOffered, isTrue);
  });
}
