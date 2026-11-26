import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
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
    test('garbage', () => expect(parsePairUrl('hello'), isNull));
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

    testWidgets('a bad code shows badCode', (tester) async {
      await pump(tester, const Unpaired());
      expect(find.text(t('badCode')), findsOneWidget);
      expect(tvs.all, isEmpty);
    });
  });
}
