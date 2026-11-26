import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv_companion/i18n.dart';
import 'package:ilonatv_companion/tv_client.dart';
import 'package:ilonatv_companion/tvs.dart';
import 'package:ilonatv_companion/ui/remote_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

Item item(String title, [String type = 'movie']) => {
  'type': type,
  'id': title,
  'title': title,
  'year': 2020,
  'genre': 'Drama',
  'rating': 7.5,
  'overview': 'About $title',
};

class Fake extends TvClient {
  Fake() : super('1.2.3.4');
  final queries = <String>[];
  final opened = <Map>[];
  Completer<void>? gate;
  int rowCalls = 0;
  TvResult<bool> openResult = const Ok(true);
  SearchResults results = SearchResults(
    [item('Dune')],
    const [],
    [item('Clip', 'video')],
  );

  @override
  Stream<TvInfo> events() => StreamController<TvInfo>().stream;

  @override
  Future<TvResult<SearchResults>> search(String q) async {
    queries.add(q);
    if (gate != null) await gate!.future;
    return Ok(results);
  }

  TvResult<List<TvRow>>? rowsFail;

  @override
  Future<TvResult<List<TvRow>>> rows() async =>
      (rowCalls++, rowsFail).$2 ??
      Ok([
        TvRow('trending', 'Trending now', [item('Alien')]),
        TvRow('yt', 'Videos', [item('Clip', 'video')]),
      ]);

  @override
  Future<TvResult<bool>> open(Map i) async {
    opened.add(i);
    if (gate != null) await gate!.future;
    return openResult;
  }
}

void main() {
  late Fake client;
  final tv = Tv(
    host: '1.2.3.4',
    port: 8642,
    name: 'IlonaTv on Box',
    token: 'x',
  );

  Future<void> start(
    WidgetTester t,
    String tab, {
    double scale = 1,
    bool fail = false,
  }) async {
    SharedPreferences.setMockInitialValues({});
    I18n.language = 'en';
    client = Fake();
    if (fail) client.rowsFail = const Unreachable('x');
    await t.pumpWidget(
      MaterialApp(
        builder: (c, w) => MediaQuery(
          data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale)),
          child: w!,
        ),
        home: RemotePage(tv: tv, client: client, tvs: Tvs()),
      ),
    );
    await t.tap(find.text(tab));
    await t.pumpAndSettle();
  }

  testWidgets('search debounces and shows only non-empty sections', (t) async {
    await start(t, 'Search');
    await t.enterText(find.byType(TextField), 'd');
    await t.pump(const Duration(milliseconds: 200));
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 399));
    expect(client.queries, isEmpty);
    await t.pump(const Duration(milliseconds: 2));
    await t.pumpAndSettle();
    expect(client.queries, ['dune']);
    expect(find.text('Movies'), findsOneWidget);
    expect(find.text('Series'), findsNothing);
    expect(find.text('YouTube'), findsOneWidget);
    expect(find.text('Dune'), findsOneWidget);
  });

  testWidgets('browse renders rows', (t) async {
    await start(t, 'Browse');
    expect(find.text('Trending now'), findsOneWidget);
    expect(find.text('Alien'), findsOneWidget);
  });

  testWidgets('watch opens the same item map and closes the sheet', (t) async {
    await start(t, 'Browse');
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    expect(find.text('About Alien'), findsOneWidget);
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(client.opened.single, item('Alien'));
    expect(find.text('Opening on the TV'), findsOneWidget);
    expect(find.text('About Alien'), findsNothing);
  });

  testWidgets('open false says the TV could not open it', (t) async {
    await start(t, 'Browse');
    client.openResult = const Ok(false);
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(find.text("The TV couldn't open this"), findsOneWidget);
  });

  testWidgets('409 on watch shows the banner', (t) async {
    await start(t, 'Browse');
    client.openResult = const NotInFront(launcherMode: false);
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(find.text('Open IlonaTv on the TV'), findsOneWidget);
  });

  testWidgets('rows with videos do not overflow, even at 1.5x text', (t) async {
    await start(t, 'Browse', scale: 1.5);
    expect(t.takeException(), isNull);
    expect(find.text('Clip'), findsOneWidget);
  });

  testWidgets('search grids do not overflow at 1.5x text', (t) async {
    await start(t, 'Search', scale: 1.5);
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'open false shows the message inside the sheet, which stays open',
    (t) async {
      await start(t, 'Browse');
      client.openResult = const Ok(false);
      await t.tap(find.text('Alien'));
      await t.pumpAndSettle();
      await t.tap(find.byKey(const Key('watch')));
      await t.pumpAndSettle();
      expect(find.byKey(const Key('cantOpen')), findsOneWidget);
      expect(find.byKey(const Key('watch')), findsOneWidget);
    },
  );

  testWidgets('a failed first load shows Retry, and Retry loads', (t) async {
    await start(t, 'Browse', fail: true);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    client.rowsFail = null;
    await t.tap(find.text('Retry').last);
    await t.pumpAndSettle();
    expect(find.text('Trending now'), findsOneWidget);
  });

  testWidgets('a sheet closed while Watch is pending leaves the remote', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    I18n.language = 'en';
    client = Fake();
    await t.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (c) => TextButton(
            onPressed: () => Navigator.of(c).push(
              MaterialPageRoute(
                builder: (_) => RemotePage(tv: tv, client: client, tvs: Tvs()),
              ),
            ),
            child: const Text('go'),
          ),
        ),
      ),
    );
    await t.tap(find.text('go'));
    await t.pumpAndSettle();
    await t.tap(find.text('Browse'));
    await t.pumpAndSettle();
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    client.gate = Completer();
    await t.tap(find.byKey(const Key('watch')));
    await t.pump();
    expect(
      find.descendant(
        of: find.byKey(const Key('watch')),
        matching: find.byType(CircularProgressIndicator),
      ),
      findsOneWidget,
    );
    await t.tapAt(const Offset(10, 10));
    await t.pumpAndSettle();
    expect(find.text('About Alien'), findsNothing);
    client.gate!.complete();
    await t.pumpAndSettle();
    expect(find.byType(RemotePage), findsOneWidget);
  });

  testWidgets('a running search shows progress', (t) async {
    await start(t, 'Search');
    client.gate = Completer();
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 450));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    client.gate!.complete();
    await t.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Dune'), findsOneWidget);
  });

  testWidgets('Search and Browse keep their state across tabs', (t) async {
    await start(t, 'Search');
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
    await t.tap(find.text('Browse'));
    await t.pumpAndSettle();
    await t.tap(find.text('Search'));
    await t.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'dune'), findsOneWidget);
    await t.tap(find.text('Browse'));
    await t.pumpAndSettle();
    expect(client.rowCalls, 1);
  });
}
