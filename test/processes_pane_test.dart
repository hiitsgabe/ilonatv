import 'package:elimor/host.dart';
import 'package:elimor/ui/processes_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

String _record(String name, String pss, int adj) =>
    '  *APP* UID 10001 ProcessRecord{a 1:$name/u0a1}\n'
    '    adjSeq=1 lruSeq=0 lastPss=$pss lastSwapPss=0.00\n'
    '    oom: max=1001 curRaw=$adj setRaw=$adj cur=$adj set=$adj\n';

final _dump = [
  _record('app.elimor.app', '128MB', 0),
  _record('com.example.vpn', '59MB', 200),
  _record('com.amazon.tv.ime', '24MB', 200),
  _record('com.stremio.one:stremio_server_process', '94MB', 905),
  _record('com.stremio.one', '10MB', 906),
  _record('com.amazon.diode', '9MB', 910),
].join();

const _apps = {
  'app.elimor.app': InstalledApp('app.elimor.app', 'Elimor', tv: true),
  'com.example.vpn': InstalledApp('com.example.vpn', 'Example VPN'),
  'com.stremio.one': InstalledApp('com.stremio.one', 'Stremio'),
  'com.amazon.tv.ime': InstalledApp('com.amazon.tv.ime', 'Keyboard', tv: true),
};

void main() {
  setUp(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('app.elimor/host'),
          (_) async => null,
        ),
  );

  testWidgets('lists the running apps a person knows, biggest first; Close '
      'goes the system way in the background, by Force stop otherwise; '
      'Clean closes them all and says what it freed', (tester) async {
    final killed = <String>[], stopped = <String>[];
    var free = 300000;
    int Function()? freeAt;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessesPane(
            _apps,
            grant: const ['adb grant'],
            processes: () async => (
              dump: _dump,
              availKb: freeAt?.call() ?? free,
              totalKb: 1703156,
            ),
            killBackground: (p) async {
              killed.add(p);
              return true;
            },
            forceStop: (p) async {
              stopped.add(p);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('293 MB free of 1663 MB'), findsOneWidget);
    // Not Elimor, not the keyboard, not a package with no app.
    expect(find.text('Elimor'), findsNothing);
    expect(find.text('Keyboard'), findsNothing);
    final stremio = tester.getTopLeft(find.text('Stremio'));
    final vpn = tester.getTopLeft(find.text('Example VPN'));
    expect(stremio.dy, lessThan(vpn.dy));
    expect(find.text('104 MB · Cached'), findsOneWidget);
    expect(find.text('59 MB · Active'), findsOneWidget);

    // Each Close is a Force stop; the next waits for Elimor to come back.
    Future<void> back() async {
      for (final s in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(s);
      }
      await tester.pumpAndSettle();
    }

    await tester.tap(find.text('Stremio'));
    await tester.pumpAndSettle();
    expect(stopped, ['com.stremio.one']);
    // Still waiting for Elimor: a second press does nothing.
    await tester.tap(find.text('Example VPN'));
    await tester.pumpAndSettle();
    expect(stopped, ['com.stremio.one']);
    await back();
    await tester.tap(find.text('Example VPN'));
    await tester.pumpAndSettle();
    await back();
    expect(stopped, ['com.stremio.one', 'com.example.vpn']);
    expect(killed, isEmpty);

    stopped.clear();
    // Clean reads the free memory before and after, closing one at a time.
    var reads = 0;
    freeAt = () => reads++ == 0 ? 300000 : 410000;
    await tester.tap(find.text('Clean'));
    await tester.pumpAndSettle();
    expect(stopped, ['com.stremio.one']);
    await back();
    expect(stopped, ['com.stremio.one', 'com.example.vpn']);
    await back();
    expect(find.text('Freed 107 MB'), findsOneWidget);
  });

  testWidgets('an app with an accessibility service on stays out; Close '
      'without the service says to turn Launcher mode on', (tester) async {
    final killed = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessesPane(
            _apps,
            grant: const [],
            processes: () async =>
                (dump: _dump, availKb: 300000, totalKb: 1703156),
            keepRunning: () async => {'com.stremio.one'},
            forceStop: (_) async => false,
            killBackground: (p) async {
              killed.add(p);
              return true;
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Stremio'), findsNothing);
    await tester.tap(find.text('Example VPN'));
    await tester.pumpAndSettle();
    expect(
      find.text('Turn on Launcher mode to close this one'),
      findsOneWidget,
    );
  });

  testWidgets('without DUMP: the command to grant it', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProcessesPane(
            _apps,
            grant: const ['adb shell pm grant app.elimor.app DUMP'],
            processes: () async =>
                (dump: 'Permission Denial: no DUMP', availKb: 0, totalKb: 0),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('adb shell pm grant app.elimor.app DUMP'), findsOneWidget);
  });
}
