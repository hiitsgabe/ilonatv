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
        TvRow('games:soccer', 'Games', [
          {
            ...item('Galo x Cruzeiro', 'game'),
            'game': {
              'state': 'in',
              'detail': "62'",
              'home': {'abbr': 'CAM', 'color': '000000', 'score': '2'},
              'away': {'abbr': 'CRU', 'color': '0033A0', 'score': '1'},
            },
          },
        ]),
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
    name: 'Ilona TV on Box',
    token: 'x',
  );

  Future<void> start(
    WidgetTester t, {
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
    await t.tap(find.text('Explore'));
    await t.pumpAndSettle();
  }

  Finder inResults(String text) => find.descendant(
    of: find.byType(CustomScrollView),
    matching: find.text(text),
  );

  Future<void> search(WidgetTester t, String q) async {
    await t.enterText(find.byType(TextField), q);
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
  }

  testWidgets('search debounces and shows only non-empty sections', (t) async {
    await start(t);
    await t.enterText(find.byType(TextField), 'd');
    await t.pump(const Duration(milliseconds: 200));
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 399));
    expect(client.queries, isEmpty);
    await t.pump(const Duration(milliseconds: 2));
    await t.pumpAndSettle();
    expect(client.queries, ['dune']);
    expect(inResults('Movies'), findsOneWidget);
    expect(find.text('Series'), findsNothing, reason: 'no chip, no section');
    expect(find.text('Dune'), findsOneWidget);
    await t.dragUntilVisible(
      inResults('YouTube'),
      find.byType(CustomScrollView),
      const Offset(0, -200),
    );
    expect(inResults('YouTube'), findsOneWidget);
  });

  testWidgets('the rows show while the field is empty, results once it is '
      'not, and a chip keeps one kind', (t) async {
    await start(t);
    expect(find.text('Trending now'), findsOneWidget);
    await search(t, 'dune');
    expect(find.text('Trending now'), findsNothing);
    await t.tap(find.byKey(const Key('filter-videos')));
    await t.pumpAndSettle();
    expect(inResults('Movies'), findsNothing);
    expect(inResults('YouTube'), findsOneWidget);
    await t.tap(find.byTooltip('Clear'));
    await t.pumpAndSettle();
    expect(find.text('Trending now'), findsOneWidget);
  });

  testWidgets('browse renders rows', (t) async {
    await start(t);
    expect(find.text('Trending now'), findsOneWidget);
    expect(find.text('Alien'), findsOneWidget);
  });

  testWidgets('a game shows both teams and the score, live, and opens '
      'nothing', (t) async {
    await start(t);
    await t.scrollUntilVisible(
      find.text('Galo x Cruzeiro'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .last,
    );
    expect(find.text('CAM'), findsOneWidget);
    expect(find.text('CRU'), findsOneWidget);
    expect(find.text('2 – 1'), findsOneWidget);
    expect(find.text('LIVE'), findsOneWidget);
    await t.tap(find.text('Galo x Cruzeiro'));
    await t.pumpAndSettle();
    expect(find.text('Watch on Ilona TV on Box'), findsNothing);
  });

  testWidgets('watch opens the same item map, closes the sheet and goes back '
      'to the remote', (t) async {
    await start(t);
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    expect(find.text('About Alien'), findsOneWidget);
    expect(find.text('Watch on Ilona TV'), findsOneWidget);
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(client.opened.single, item('Alien'));
    expect(find.text('Opening on Ilona TV'), findsOneWidget);
    expect(find.text('About Alien'), findsNothing);
    expect(find.byKey(const Key('pad')), findsOneWidget);
  });

  testWidgets('open false says the TV could not open it', (t) async {
    await start(t);
    client.openResult = const Ok(false);
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(find.text("The TV couldn't open this"), findsOneWidget);
  });

  testWidgets('409 on watch shows the banner', (t) async {
    await start(t);
    client.openResult = const NotInFront(launcherMode: false);
    await t.tap(find.text('Alien'));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const Key('watch')));
    await t.pumpAndSettle();
    expect(find.text('Open Ilona TV on the TV'), findsOneWidget);
  });

  testWidgets('rows with videos do not overflow, even at 1.5x text', (t) async {
    await start(t, scale: 1.5);
    expect(t.takeException(), isNull);
    expect(find.text('Clip'), findsOneWidget);
  });

  testWidgets('search grids do not overflow at 1.5x text', (t) async {
    await start(t, scale: 1.5);
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 450));
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'open false shows the message inside the sheet, which stays open',
    (t) async {
      await start(t);
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
    await start(t, fail: true);
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
    await t.tap(find.text('Explore'));
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
    await start(t);
    client.gate = Completer();
    await t.enterText(find.byType(TextField), 'dune');
    await t.pump(const Duration(milliseconds: 450));
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    client.gate!.complete();
    await t.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Dune'), findsOneWidget);
  });

  testWidgets('Explore keeps its state across tabs', (t) async {
    await start(t);
    await search(t, 'dune');
    await t.tap(find.text('Remote'));
    await t.pumpAndSettle();
    await t.tap(find.text('Explore'));
    await t.pumpAndSettle();
    expect(find.text('Dune'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'dune'), findsOneWidget);
    expect(client.rowCalls, 1);
  });
}
