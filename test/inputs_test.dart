import 'package:elimor/data/inputs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// An input as HostChannel.tvInputs sends it: a connected HDMI port unless
/// told otherwise.
Map<String, Object?> _raw(
  String id, {
  String? label,
  String? systemLabel,
  int type = kTypeHdmi,
  String? parent,
  bool hidden = false,
  int? state = kStateConnected,
  String? device,
}) => {
  'id': id,
  'type': type,
  'parent': parent,
  'hidden': hidden,
  'state': state,
  'label': label ?? systemLabel ?? id,
  'systemLabel': systemLabel ?? id,
  'device': device,
};

const _hw = 'com.mediatek.tvinput/.hdmi.HDMIInputService/HW';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('app.elimor/host');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('visibleInputs: HDMI ports that are shown and on, connected or in '
      'standby; a state not told counts as on', () {
    final cards = visibleInputs([
      _raw('connected', systemLabel: 'HDMI 1'),
      _raw('standby', systemLabel: 'HDMI 2', state: kStateStandby),
      _raw('unknown', systemLabel: 'HDMI 3', state: null),
      _raw('disconnected', systemLabel: 'HDMI 4', state: 2),
      _raw('hidden', systemLabel: 'HDMI 5', hidden: true),
      _raw('tuner', type: 0),
      _raw('child', parent: 'connected', device: 'Soundbar'),
    ]);
    expect(cards.map((c) => c.title), ['HDMI 1', 'HDMI 2', 'HDMI 3']);
    // A port with a child opens the child (the CEC device's input), the
    // others open the port.
    expect(cards.map((c) => c.id), ['child', 'standby', 'unknown']);
  });

  test('visibleInputs: the device is the port\'s CEC name, else a shown '
      'child\'s, else its label', () {
    final cards = visibleInputs([
      _raw('a', systemLabel: 'HDMI 1', device: 'PlayStation 5'),
      _raw('a/child', parent: 'a', device: 'Other'),
      _raw('b', systemLabel: 'HDMI 2'),
      _raw('b/hidden', parent: 'b', hidden: true, device: 'Hidden'),
      _raw('b/child', parent: 'b', device: 'Xbox'),
      _raw('c', systemLabel: 'HDMI 3'),
      _raw('c/child', parent: 'c', label: 'Apple TV'),
      _raw('d', systemLabel: 'HDMI 4'),
    ]);
    expect(
      [for (final c in cards) (c.id, c.genre)],
      [
        ('a/child', 'PlayStation 5'),
        ('b/child', 'Xbox'), // the hidden child is not it
        ('c/child', 'Apple TV'),
        ('d', ''),
      ],
    );
  });

  test('visibleInputs: by the port in the system label, whatever the user '
      'named it; then by the number in the id, then the id', () {
    final cards = visibleInputs([
      _raw('${_hw}3', label: 'Apple TV 4K', systemLabel: 'HDMI 3'),
      _raw('${_hw}1', label: 'PS5', systemLabel: 'HDMI 1'),
      _raw('${_hw}2', label: 'Xbox', systemLabel: 'HDMI 2'),
    ]);
    expect(cards.map((c) => c.title), ['PS5', 'Xbox', 'Apple TV 4K']);

    final byId = visibleInputs([
      _raw('${_hw}10', systemLabel: 'HDMI'),
      _raw('${_hw}2b', systemLabel: 'HDMI'),
      _raw('${_hw}2a', systemLabel: 'HDMI'),
      _raw('x/HW', systemLabel: 'HDMI'),
    ]);
    expect(byId.map((c) => c.id), ['${_hw}2a', '${_hw}2b', '${_hw}10', 'x/HW']);
  });

  test('loadInputs: the visible ones; none when the host fails or has '
      'none', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => [
        _raw('b', systemLabel: 'HDMI 2'),
        _raw('a', systemLabel: 'HDMI 1'),
        _raw('off', state: 2),
      ],
    );
    expect((await loadInputs()).map((i) => i.id), ['a', 'b']);
    messenger.setMockMethodCallHandler(channel, (_) async => null);
    expect(await loadInputs(), isEmpty);
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw PlatformException(code: 'x'),
    );
    expect(await loadInputs(), isEmpty);
  });
}
