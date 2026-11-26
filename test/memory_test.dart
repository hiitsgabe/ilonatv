import 'package:ilonatv/data/media.dart';
import 'package:ilonatv/host.dart';
import 'package:ilonatv/ui/apps_screen.dart';
import 'package:ilonatv/ui/backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// A 1×1 PNG.
final _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, //
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
  0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x00, 0x02, 0x00,
  0x00, 0x05, 0x00, 0x01, 0x7A, 0x5E, 0xAB, 0x3F, 0x00, 0x00, 0x00, 0x00,
  0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

bool _tracked(ImageProvider p) {
  late Object key;
  p.obtainKey(ImageConfiguration.empty).then((k) => key = k);
  return imageCache.statusForKey(key).tracked;
}

void main() {
  tearDown(() => imageCache.clear());

  testWidgets('one decoded backdrop: the outgoing one leaves imageCache, '
      'and comes back from its kept bytes', (tester) async {
    final bytes = {
      for (final u in ['a', 'b', 'c']) 'https://x/$u': Uint8List.fromList(_png),
    };
    final fetched = <Uri>[];
    final real = fetchBackdrop;
    addTearDown(() => fetchBackdrop = real);
    fetchBackdrop = (uri, {timeout = const Duration(seconds: 15)}) async {
      fetched.add(uri);
      return bytes['$uri']!;
    };
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Backdrop(
          focused: ValueNotifier(null),
          rotation: [
            for (final url in bytes.keys)
              MediaItem(
                type: MediaType.movie,
                id: url,
                title: url,
                backdropUrl: url,
              ),
          ],
          dimmed: false,
          onShown: (_) {},
        ),
      ),
    );
    await tester.pump();
    List<bool> tracked() => [
      for (final b in bytes.values) _tracked(backdropImage(b)),
    ];
    expect(tracked(), [true, false, false]);

    // Two switches, each past its 600 ms crossfade.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(tracked(), [false, true, false]);
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(tracked(), [false, false, true]);

    // Around again: decoded anew from the bytes it kept, not fetched again.
    await tester.pump(const Duration(seconds: 10));
    await tester.pump(const Duration(seconds: 1));
    expect(tracked(), [true, false, false]);
    expect(fetched, hasLength(3));
  });

  testWidgets('leaving the Apps grid drops its icons, not the others', (
    tester,
  ) async {
    const channel = MethodChannel('tv.ilona/host');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (_) async => _png);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    // A home tile's icon, decoded meanwhile.
    final home = MemoryImage(Uint8List.fromList(_png));
    home.resolve(ImageConfiguration.empty);

    await tester.pumpWidget(
      const MaterialApp(
        home: AppsScreen({'com.x': InstalledApp('com.x', 'X')}),
      ),
    );
    await tester.pump();
    expect(imageCache.pendingImageCount + imageCache.currentSize, 2);

    await tester.pumpWidget(const SizedBox());
    expect(_tracked(home), isTrue);
    expect(imageCache.pendingImageCount + imageCache.currentSize, 1);
  });
}
