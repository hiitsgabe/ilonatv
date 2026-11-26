import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/pair_page.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeClient extends TvClient {
  FakeClient(super.host, this.result);
  final TvResult<String> result;
  String? code;

  @override
  Future<TvResult<String>> pair({String? code, String? secret, required String name}) async {
    this.code = code;
    return result;
  }
}

void main() {
  group('parsePairUrl', () {
    test('valid', () {
      final r = parsePairUrl('http://192.168.1.20:8642/#s=abc123')!;
      expect((r.host, r.port, r.secret), ('192.168.1.20', 8642, 'abc123'));
    });
    test('wrong scheme', () => expect(parsePairUrl('https://1.2.3.4:8642/#s=x'), isNull));
    test('missing secret', () {
      expect(parsePairUrl('http://1.2.3.4:8642/'), isNull);
      expect(parsePairUrl('http://1.2.3.4:8642/#x=1'), isNull);
    });
    test('extra query', () {
      final r = parsePairUrl('http://1.2.3.4:8642/?a=b#s=zz')!;
      expect(r.secret, 'zz');
    });
    test('no port uses the IlonaTv port', () {
      expect(parsePairUrl('http://1.2.3.4/#s=zz')!.port, kCompanionPort);
    });
    test('garbage', () => expect(parsePairUrl('hello'), isNull));
  });

  group('parseHostInput', () {
    test('accepts ip, hostname and host:port', () {
      expect(parseHostInput(' 192.168.1.5 ')!.host, '192.168.1.5');
      expect(parseHostInput('tv.local')!.host, 'tv.local');
      final p = parseHostInput('192.168.1.5:8642')!;
      expect((p.host, p.port), ('192.168.1.5', 8642));
    });
    test('rejects scheme, path, spaces, bad octet, bad port', () {
      for (final s in [
        'http://192.168.1.5',
        '192.168.1.5/x',
        '192 168 1 5',
        '300.1.1.1',
        '1.2.3.4:99999',
        '1.2.3.4:',
        '',
      ]) {
        expect(parseHostInput(s), isNull, reason: s);
      }
    });
  });

  group('pair by code', () {
    late Tvs tvs;
    setUp(() {
      I18n.language = 'en';
      SharedPreferences.setMockInitialValues({});
      tvs = Tvs();
    });

    Future<FakeClient> pump(WidgetTester tester, TvResult<String> result) async {
      final fake = FakeClient('10.0.0.5', result);
      await tester.pumpWidget(
        MaterialApp(home: PairPage(tvs: tvs, clientFor: (_) => fake, host: '10.0.0.5')),
      );
      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.text(t('pairNow')));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      return fake;
    }

    testWidgets('saves the TV and opens the remote', (tester) async {
      final fake = await pump(tester, const Ok('tok'));
      expect(fake.code, '123456');
      expect(tvs.all.single.token, 'tok');
      expect(find.byType(RemotePage), findsOneWidget);
    });

    testWidgets('an invalid address is not sent', (tester) async {
      final fake = FakeClient('x', const Ok('tok'));
      await tester.pumpWidget(
        MaterialApp(home: PairPage(tvs: tvs, clientFor: (_) => fake, host: 'http://1.2.3.4')),
      );
      await tester.enterText(find.byType(TextField).last, '123456');
      await tester.pump();
      await tester.tap(find.text(t('pairNow')));
      await tester.pump();
      expect(find.text(t('badAddress')), findsOneWidget);
      expect(fake.code, isNull);
    });

    testWidgets('a bad code shows badCode', (tester) async {
      await pump(tester, const Unpaired());
      expect(find.text(t('badCode')), findsOneWidget);
      expect(tvs.all, isEmpty);
    });
  });
}
