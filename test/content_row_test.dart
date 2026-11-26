import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/data/tmdb.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/ui/content_row.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('clampFocus', () {
    expect(clampFocus(5, 0), 0);
    expect(clampFocus(5, 3), 2);
    expect(clampFocus(1, 3), 1);
    expect(clampFocus(-1, 3), 0);
  });

  testWidgets('a row without images keeps its grey boxes, no Image', (
    tester,
  ) async {
    Widget row(bool images) => MaterialApp(
      home: Scaffold(
        body: ContentRow(
          title: 'Row',
          images: images,
          items: const [
            MediaItem(
              type: MediaType.movie,
              id: 'a',
              title: 'A',
              posterUrl: 'https://example.com/a.jpg',
            ),
          ],
          onFocus: (_) {},
          onOpen: (_) {},
        ),
      ),
    );
    await tester.pumpWidget(row(false));
    expect(find.byType(Image), findsNothing);
    expect(find.text('A'), findsWidgets);
    await tester.pumpWidget(row(true));
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a card with progress has a bar as long at its bottom', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContentRow(
            title: 'Row',
            wide: true,
            items: const [
              MediaItem(type: MediaType.video, id: 'a', title: 'A'),
              MediaItem(
                type: MediaType.video,
                id: 'b',
                title: 'B',
                progress: 0.25,
              ),
            ],
            onFocus: (_) {},
            onOpen: (_) {},
          ),
        ),
      ),
    );
    final bar = find.byKey(const ValueKey('progress'));
    expect(bar, findsOneWidget);
    final track = tester.getRect(bar);
    final fill = tester.getRect(
      find.descendant(of: bar, matching: find.byType(ColoredBox)).last,
    );
    expect(track.height, 3);
    expect(fill.width, closeTo(track.width / 4, 0.01));
    expect(fill.bottomLeft, track.bottomLeft);
  });

  testWidgets('a row come back to from a card further right shows the card it '
      'remembers, at its margin', (tester) async {
    List<MediaItem> items(String row) => [
      for (var i = 0; i < 20; i++)
        MediaItem(type: MediaType.movie, id: '$row$i', title: '$row$i'),
    ];
    MediaItem? focused;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final row in ['a', 'b'])
                ContentRow(
                  title: row,
                  items: items(row),
                  onFocus: (item) => focused = item ?? focused,
                  onOpen: (_) {},
                ),
            ],
          ),
        ),
      ),
    );
    Future<void> press(LogicalKeyboardKey key, [int times = 1]) async {
      for (var i = 0; i < times; i++) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
    }

    double offset(int row) => tester
        .state<ScrollableState>(find.byType(Scrollable).at(row))
        .position
        .pixels;

    // Row b remembers its first card; row a is then run to its end, where
    // the last card sits far right of b's first.
    await press(LogicalKeyboardKey.tab);
    await press(LogicalKeyboardKey.arrowDown);
    expect(focused!.id, 'b0');
    await press(LogicalKeyboardKey.arrowUp);
    await press(LogicalKeyboardKey.arrowRight, 19);
    expect(focused!.id, 'a19');
    expect(offset(0), greaterThan(0));

    await press(LogicalKeyboardKey.arrowDown);
    expect(focused!.id, 'b0');
    expect(offset(1), 0, reason: 'the row did not scroll to another card');
  });

  group('filter card', () {
    List<MediaItem> items(String row, [int n = 5]) => [
      for (var i = 0; i < n; i++)
        MediaItem(type: MediaType.movie, id: '$row$i', title: '$row$i'),
    ];
    const services = [
      WatchProvider(8, 'Netflix', null),
      WatchProvider(350, 'Apple TV+', null),
    ];
    final card = find.byKey(const ValueKey('filter'));
    String? rowWithFocus() => primaryFocus?.context
        ?.findAncestorWidgetOfExactType<ContentRow>()
        ?.title;

    testWidgets('Left on the first card opens the filter; Up/Down change the '
        'service and stay in the row; Right closes it', (tester) async {
      int? picked;
      var changes = 0;
      MediaItem? focusedA, focusedB;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  ContentRow(
                    title: 'a',
                    items: items('a'),
                    filter: RowFilter(
                      options: services,
                      selected: picked,
                      onChanged: (id) => setState(() {
                        picked = id;
                        changes++;
                      }),
                    ),
                    onFocus: (item) => focusedA = item ?? focusedA,
                    onOpen: (_) {},
                  ),
                  ContentRow(
                    title: 'b',
                    items: items('b'),
                    onFocus: (item) => focusedB = item ?? focusedB,
                    onOpen: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.tab);
      expect(focusedA!.id, 'a0');
      expect(card, findsNothing);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(card, findsOneWidget);
      expect(find.text(t('allProviders')), findsOneWidget);
      expect(rowWithFocus(), 'a');
      await press(LogicalKeyboardKey.arrowUp); // All is the first: no change
      expect((picked, changes), (null, 0));
      await press(LogicalKeyboardKey.arrowDown);
      expect((picked, changes), (8, 1));
      expect(find.text('Netflix'), findsOneWidget, reason: 'no logo: the name');
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown); // at the end: no change
      expect((picked, changes), (350, 2));
      await press(LogicalKeyboardKey.arrowUp);
      expect((picked, changes), (8, 3));
      expect(focusedB, isNull, reason: 'the second row never got focus');
      expect(rowWithFocus(), 'a');
      expect(card, findsOneWidget);
      await press(LogicalKeyboardKey.arrowRight);
      expect(card, findsNothing);
      expect(focusedA!.id, 'a0');
      expect(rowWithFocus(), 'a');
      // Left again: the card comes back.
      await press(LogicalKeyboardKey.arrowLeft);
      expect(card, findsOneWidget);
    });

    testWidgets('the card stays, with focus, while the row is empty; focus '
        'leaving it is still heard', (tester) async {
      var row = items('a', 1);
      late StateSetter rebuild;
      final heard = <MediaItem?>[];
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return Column(
                  children: [
                    ContentRow(
                      title: 'a',
                      items: row,
                      filter: RowFilter(
                        options: services,
                        selected: 8,
                        onChanged: (_) {},
                      ),
                      onFocus: heard.add,
                      onOpen: (_) {},
                    ),
                    Focus(
                      focusNode: other,
                      child: const SizedBox.square(dimension: 10),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      rebuild(() => row = []);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(rowWithFocus(), 'a');
      expect(heard.map((i) => i?.id), ['a0'], reason: 'focus is still here');
      // Right has no title to go to.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(card, findsOneWidget);
      expect(rowWithFocus(), 'a');
      other.requestFocus();
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(heard.map((i) => i?.id), ['a0', null]);
    });

    const genres = [Genre('cmy', 'Comedy'), Genre('hrr', 'Horror')];
    final genreCard = find.byKey(const ValueKey('genre'));

    testWidgets('Left on the service card opens the genre card; Up/Down pick '
        'the genre and stay in the row; Right goes back to the service card, '
        'then to the first title', (tester) async {
      int? service;
      String? genre;
      var genreChanges = 0;
      MediaItem? focusedA, focusedB;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  ContentRow(
                    title: 'a',
                    items: items('a'),
                    filter: RowFilter(
                      options: services,
                      selected: service,
                      onChanged: (id) => setState(() => service = id),
                      genres: genres,
                      genre: genre,
                      onGenre: (code) => setState(() {
                        genre = code;
                        genreChanges++;
                      }),
                    ),
                    onFocus: (item) => focusedA = item ?? focusedA,
                    onOpen: (_) {},
                  ),
                  ContentRow(
                    title: 'b',
                    items: items('b'),
                    onFocus: (item) => focusedB = item ?? focusedB,
                    onOpen: (_) {},
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      Future<void> press(LogicalKeyboardKey key) async {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }

      await press(LogicalKeyboardKey.tab);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(genreCard, findsNothing);
      await press(LogicalKeyboardKey.arrowLeft);
      expect(genreCard, findsOneWidget);
      expect(card, findsOneWidget, reason: 'the service card stays up');
      expect(find.text(t('allProviders')), findsNWidgets(2));
      expect(rowWithFocus(), 'a');
      await press(LogicalKeyboardKey.arrowUp); // All is the first: no change
      expect((genre, genreChanges), (null, 0));
      await press(LogicalKeyboardKey.arrowDown);
      expect((genre, genreChanges), ('cmy', 1));
      expect(find.text('Comedy'), findsOneWidget);
      await press(LogicalKeyboardKey.arrowDown);
      await press(LogicalKeyboardKey.arrowDown); // at the end: no change
      expect((genre, genreChanges), ('hrr', 2));
      await press(LogicalKeyboardKey.arrowUp);
      expect((genre, genreChanges), ('cmy', 3));
      expect(service, isNull, reason: 'the service card did not hear them');
      expect(focusedB, isNull, reason: 'the second row never got focus');
      expect(rowWithFocus(), 'a');
      // Right: back to the service card, which Down then moves.
      await press(LogicalKeyboardKey.arrowRight);
      expect(genreCard, findsNothing);
      expect(card, findsOneWidget);
      await press(LogicalKeyboardKey.arrowDown);
      expect(service, 8);
      expect(genreChanges, 3);
      // Right again: the first title.
      await press(LogicalKeyboardKey.arrowRight);
      expect(card, findsNothing);
      expect(focusedA!.id, 'a0');
    });

    testWidgets('focus leaving the genre card takes both cards down', (
      tester,
    ) async {
      final heard = <MediaItem?>[];
      final other = FocusNode();
      addTearDown(other.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                ContentRow(
                  title: 'a',
                  items: items('a'),
                  filter: RowFilter(
                    options: services,
                    selected: null,
                    onChanged: (_) {},
                    genres: genres,
                    onGenre: (_) {},
                  ),
                  onFocus: heard.add,
                  onOpen: (_) {},
                ),
                Focus(
                  focusNode: other,
                  child: const SizedBox.square(dimension: 10),
                ),
              ],
            ),
          ),
        ),
      );
      for (final key in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(genreCard, findsOneWidget);
      expect(card, findsOneWidget);
      other.requestFocus();
      await tester.pumpAndSettle();
      expect(genreCard, findsNothing);
      expect(card, findsNothing);
      expect(heard.map((i) => i?.id), ['a0', null]);
    });

    testWidgets('a filter without genres keeps Left on the service card '
        'swallowed', (tester) async {
      int? service;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => ContentRow(
                title: 'a',
                items: items('a'),
                filter: RowFilter(
                  options: services,
                  selected: service,
                  onChanged: (id) => setState(() => service = id),
                ),
                onFocus: (_) {},
                onOpen: (_) {},
              ),
            ),
          ),
        ),
      );
      for (final key in [
        LogicalKeyboardKey.tab,
        LogicalKeyboardKey.arrowLeft,
        LogicalKeyboardKey.arrowLeft,
      ]) {
        await tester.sendKeyEvent(key);
        await tester.pumpAndSettle();
      }
      expect(genreCard, findsNothing);
      expect(card, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(service, 8, reason: 'the service card kept focus');
    });

    testWidgets('a row without a filter ignores Left on the first card as '
        'before', (tester) async {
      MediaItem? focused;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ContentRow(
              title: 'a',
              items: items('a'),
              onFocus: (item) => focused = item ?? focused,
              onOpen: (_) {},
            ),
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(card, findsNothing);
      expect(focused!.id, 'a0');
      expect(rowWithFocus(), 'a');
    });
  });
}
