import 'package:elimor/host.dart';
import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('app.elimor/host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late MethodCall received;

  void reply(Object? value) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      received = call;
      return value;
    });
  }

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('injectKey sends the key name; false without a reply', () async {
    reply(true);
    expect(await Host.injectKey(RemoteKey.left), isTrue);
    expect(received.method, 'injectKey');
    expect(received.arguments, {'key': 'left'});
    reply(null);
    expect(await Host.injectKey(RemoteKey.ok), isFalse);
  });

  test('injectKey home is false with no home to go to', () async {
    Host.onGoHome = null;
    expect(await Host.injectKey(RemoteKey.home), isFalse);
  });

  test('injectKey home goes home in Dart, not over the channel', () async {
    received = const MethodCall('none');
    reply(false);
    var went = 0;
    Host.onGoHome = () => went++;
    expect(await Host.injectKey(RemoteKey.home), isTrue);
    Host.goHome();
    expect(went, 2);
    expect(received.method, 'none');
  });

  test('advertise and unadvertise', () async {
    reply(null);
    await Host.advertise(8642, 'x');
    expect(received.method, 'advertise');
    expect(received.arguments, {'port': 8642, 'name': 'x'});
    await Host.unadvertise();
    expect(received.method, 'unadvertise');
  });

  test('listApps maps channel reply', () async {
    reply([
      {'package': 'org.smarttube.stable', 'label': 'SmartTube'},
    ]);
    final apps = await Host.listApps();
    expect(received.method, 'listApps');
    expect(apps.single.package, 'org.smarttube.stable');
    expect(apps.single.label, 'SmartTube');
    // Without the flags, an app reads as the user's, so it shows.
    expect([apps.single.tv, apps.single.system], [false, false]);

    reply([
      {'package': 'a', 'label': 'A', 'tv': true, 'system': true},
    ]);
    final a = (await Host.listApps()).single;
    expect([a.tv, a.system], [true, true]);
  });

  test('offeredApps: TV apps and user apps, never phone-only system apps, '
      'minus the hidden, in order', () {
    const apps = {
      'tv.sys': InstalledApp('tv.sys', 'A', tv: true, system: true),
      'phone.sys': InstalledApp('phone.sys', 'B', system: true),
      'phone.user': InstalledApp('phone.user', 'C'),
      'tv.user': InstalledApp('tv.user', 'D', tv: true),
      'hidden': InstalledApp('hidden', 'E', tv: true, system: true),
    };
    expect(offeredApps(apps, {'hidden'}).keys, [
      'tv.sys',
      'phone.user',
      'tv.user',
    ]);
    expect(offeredApps(apps).keys, [
      'tv.sys',
      'phone.user',
      'tv.user',
      'hidden',
    ]);
  });

  test('appIcon sends package argument and maps the reply', () async {
    reply(Uint8List.fromList([1, 2, 3]));
    expect(await Host.appIcon('com.x'), [1, 2, 3]);
    expect(received.method, 'appIcon');
    expect(received.arguments, {'package': 'com.x'});

    reply(null);
    expect(await Host.appIcon('com.x'), isNull);
  });

  test('launch sends package argument', () async {
    reply(true);
    expect(await Host.launch('com.stremio.one'), isTrue);
    expect(received.method, 'launch');
    expect(received.arguments, {'package': 'com.stremio.one'});
  });

  test('open sends uri and optional package', () async {
    reply(true);
    expect(
      await Host.open('vnd.youtube:abc', package: 'org.smarttube.stable'),
      isTrue,
    );
    expect(received.method, 'open');
    expect(received.arguments, {
      'uri': 'vnd.youtube:abc',
      'package': 'org.smarttube.stable',
    });

    expect(await Host.open('https://example.com'), isTrue);
    expect(received.arguments, {'uri': 'https://example.com', 'package': null});
  });

  test('launcherSetup maps the reply, setServiceEnabled sends on', () async {
    reply({'fireTv': true, 'serviceOn': false, 'sdk': 28});
    final s = await Host.launcherSetup();
    expect(received.method, 'launcherSetup');
    expect([s.fireTv, s.serviceOn, s.sdk], [true, false, 28]);

    reply({'fireTv': false, 'serviceOn': true});
    expect((await Host.launcherSetup()).sdk, 0);

    reply(true);
    expect(await Host.setServiceEnabled(false), isTrue);
    expect(received.method, 'setServiceEnabled');
    expect(received.arguments, {'on': false});
  });

  test('openSystemSettings sends component, action and pause', () async {
    reply(true);
    expect(
      await Host.openSystemSettings(component: 'a/.B', pause: true),
      isTrue,
    );
    expect(received.method, 'openSystemSettings');
    expect(received.arguments, {
      'component': 'a/.B',
      'action': null,
      'pause': true,
    });
  });

  test('filesDir asks the channel', () async {
    reply('/data/user/0/app.elimor.app/files');
    expect(await Host.filesDir(), '/data/user/0/app.elimor.app/files');
    expect(received.method, 'filesDir');
    expect(received.arguments, isNull);
  });

  test('setSnapshot sends the pixels with their size', () async {
    reply(null);
    final rgba = Uint8List.fromList([1, 2, 3, 4, 5, 6, 7, 8]);
    await Host.setSnapshot(rgba, 2, 1);
    expect(received.method, 'setSnapshot');
    expect(received.arguments, {'rgba': rgba, 'width': 2, 'height': 1});
    // Kotlin reads a ByteArray, so the bytes must not travel as a plain list.
    expect(received.arguments['rgba'], isA<Uint8List>());
  });

  test('tvInputs passes the raw inputs on; openInput sends the id', () async {
    final raw = {'id': 'hw1', 'type': 1007, 'state': 0, 'label': 'HDMI 1'};
    reply([raw]);
    expect(await Host.tvInputs(), [raw]);
    expect(received.method, 'tvInputs');
    reply(null);
    expect(await Host.tvInputs(), isEmpty);

    reply(true);
    expect(await Host.openInput('hw1', noSignal: 'No signal'), isTrue);
    expect(received.method, 'openInput');
    expect(received.arguments, {'id': 'hw1', 'noSignal': 'No signal'});
  });

  test('inputsChanged from Android calls onInputsChanged, goHome still '
      'onGoHome', () async {
    var inputs = 0, home = 0;
    Host.onGoHome = () => home++;
    Host.onInputsChanged = () => inputs++;
    for (final m in ['inputsChanged', 'goHome']) {
      await messenger.handlePlatformMessage(
        channel.name,
        const StandardMethodCodec().encodeMethodCall(MethodCall(m)),
        null,
      );
    }
    expect((inputs, home), (1, 1));
    Host.onInputsChanged = null;
  });

  test('goHome from Android calls onGoHome', () async {
    var calls = 0;
    Host.onGoHome = () => calls++;
    await messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(const MethodCall('goHome')),
      null,
    );
    expect(calls, 1);
  });
}
