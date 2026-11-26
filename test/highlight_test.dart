import 'package:elimor/data/media.dart';
import 'package:elimor/ui/highlight.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Text> title(WidgetTester tester, String t) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 1000,
            child: Highlight(
              item: MediaItem(type: MediaType.video, id: 'v', title: t),
            ),
          ),
        ),
      ),
    );
    return tester.widget<Text>(find.text(t));
  }

  testWidgets('a short title stays big; a long one shrinks to fit two lines', (
    tester,
  ) async {
    final short = await title(tester, 'Short');
    expect(short.style!.fontSize, 44);
    final long = await title(
      tester,
      'Daddy Yankee and Diljit Dosanjh - POKITO REACTION (Official Music '
      'Video) with a few more words to go past two lines',
    );
    expect(long.style!.fontSize, lessThan(44));
    // Always two lines: the box above the chips never changes height.
    expect(long.maxLines, 2);
  });

  testWidgets('the button names the service when there is one', (tester) async {
    Future<void> show(String? watchOn) => tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 1000,
            child: Highlight(
              item: const MediaItem(type: MediaType.movie, id: '1', title: 'F'),
              onOpen: () {},
              watchOn: watchOn,
            ),
          ),
        ),
      ),
    );
    await show(null);
    expect(find.text('Watch'), findsOneWidget);
    await show('Netflix');
    expect(find.text('Watch on Netflix'), findsOneWidget);
  });
}
