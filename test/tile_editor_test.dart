import 'dart:convert';
import 'dart:io';

import 'package:ilonatv/host.dart';
import 'package:ilonatv/i18n.dart';
import 'package:ilonatv/settings.dart';
import 'package:ilonatv/ui/tile_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _tv = 'com.example.tv';
const _uri = 'content://media/external/images/media/7';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('tv.ilona/host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory dir;
  final calls = <String>[];

  /// The host's answers: [images] for the picker's list, a fresh copy in
  /// [dir] for each `copyImage`.
  void host({List<String>? Function()? images}) {
    var n = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return switch (call.method) {
        'images' => images == null ? [_uri] : images(),
        'copyImage' => (File(
          '${dir.path}/${++n}.img',
        )..writeAsBytesSync([1])).path,
        _ => null,
      };
    });
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('tiles');
    calls.clear();
    host();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    dir.deleteSync(recursive: true);
  });

  Future<Settings> show(WidgetTester tester, List<AppTile> tiles) async {
    SharedPreferences.setMockInitialValues({
      'tiles': jsonEncode(tiles),
      'settingsTileDropped': true,
    });
    final s = await Settings.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TileEditor(s, const {_tv: InstalledApp(_tv, 'TV')}),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return s;
  }

  Future<void> key(WidgetTester tester, LogicalKeyboardKey k) async {
    await tester.sendKeyEvent(k);
    await tester.pumpAndSettle();
  }

  Future<void> openPicker(WidgetTester tester) async {
    await tester.tap(find.text(t('chooseIcon')).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text(t('customImage')));
    await tester.pumpAndSettle();
  }

  testWidgets('a custom image: pick, Centered, a swatch, saved with the '
      'tile', (tester) async {
    final s = await show(tester, [
      const AppTile(_tv, 'tv'),
      const AppTile('ilonatv:apps', 'apps'),
    ]);
    await openPicker(tester);
    expect(calls, containsAll(['images', 'imageThumb']));
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text(t('imageFill')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text(t('tileBackground')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.arrowRight);
    await key(tester, LogicalKeyboardKey.select);

    final tile = s.tiles.first;
    expect(
      (tile.package, tile.icon, tile.image, tile.centered, tile.background),
      (_tv, 'tv', '${dir.path}/1.img', true, 0xFF0E0E10),
    );
    final saved = (await SharedPreferences.getInstance()).getString('tiles');
    expect(jsonDecode(saved!)[0], tile.toJson());
  });

  testWidgets('Fill saves the image with no background; Back on the style '
      'deletes the copy', (tester) async {
    final s = await show(tester, [const AppTile(_tv, 'tv')]);
    await openPicker(tester);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.escape);
    expect(File('${dir.path}/1.img').existsSync(), isFalse);
    expect(s.tiles.first.toJson(), {'package': _tv, 'icon': 'tv'});

    await openPicker(tester);
    await key(tester, LogicalKeyboardKey.select);
    await key(tester, LogicalKeyboardKey.select);
    final tile = s.tiles.first;
    expect(
      (tile.image, tile.centered, tile.background),
      ('${dir.path}/2.img', false, null),
    );
  });

  testWidgets('a painted icon in its place, or removing the tile, deletes '
      'the copy', (tester) async {
    final a = File('${dir.path}/a.img')..writeAsBytesSync([1]);
    final b = File('${dir.path}/b.img')..writeAsBytesSync([1]);
    final s = await show(tester, [
      AppTile(_tv, 'tv', image: a.path),
      AppTile('ilonatv:apps', 'apps', image: b.path, centered: true),
    ]);
    await tester.tap(find.text(t('chooseIcon')).first);
    await tester.pumpAndSettle();
    await key(tester, LogicalKeyboardKey.select);
    expect(s.tiles.first.toJson(), {'package': _tv, 'icon': 'tv'});
    expect(a.existsSync(), isFalse);

    await tester.tap(find.text(t('removeTile')).last);
    await tester.pumpAndSettle();
    expect(s.tiles.map((t) => t.package), [_tv]);
    expect(b.existsSync(), isFalse);
  });

  testWidgets('no read access, then no pictures: says how to put some on '
      'the TV, and Check again asks again', (tester) async {
    final answers = <List<String>?>[null, []];
    host(images: () => answers.removeAt(0));
    await show(tester, [const AppTile(_tv, 'tv')]);
    await openPicker(tester);
    expect(find.text(t('imagesDenied')), findsOneWidget);
    expect(find.text(t('imagesHowTo')), findsOneWidget);
    await key(tester, LogicalKeyboardKey.select);
    expect(find.text(t('imagesNone')), findsOneWidget);
    expect(find.text(t('imagesHowTo')), findsOneWidget);
    expect(calls.where((c) => c == 'images'), hasLength(2));
  });
}
