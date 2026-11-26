import '../host.dart';
import 'media.dart';

/// `TvInputInfo.TYPE_HDMI`.
const kTypeHdmi = 1007;

/// `TvInputManager.INPUT_STATE_CONNECTED` and `INPUT_STATE_CONNECTED_STANDBY`.
const kStateConnected = 0;
const kStateStandby = 1;

/// The first number in [s] ("HDMI 2" is 2), or the last with [last] ("…/HW10"
/// is 10); none sorts after any.
int _number(Object? s, {bool last = false}) {
  final all = RegExp(r'\d+').allMatches('$s');
  final m = last ? all.lastOrNull : all.firstOrNull;
  return int.tryParse(m?.group(0) ?? '') ?? 1 << 30;
}

/// The cards of the Inputs row from every TV input ([Host.tvInputs]): the HDMI
/// ports, not their child inputs, that are not hidden and have something on
/// (a state the device will not tell counts as on). In port order: the number
/// in the system's label (the user's may be "PS5"), then the last one in the
/// id, then the id. The device is the port's HDMI-CEC name, else that of a child, else a
/// child's label. A card opens the port's first child input when it has one
/// (the HDMI-CEC device's own input, which the TV's own menu opens): the
/// TV's input service does the CEC routing for those, which wakes a console
/// in standby, and none for a bare port.
List<MediaItem> visibleInputs(List<Map> raw) {
  final ports = [
    for (final i in raw)
      if (i['type'] == kTypeHdmi &&
          i['parent'] == null &&
          i['hidden'] != true &&
          (i['state'] == null ||
              i['state'] == kStateConnected ||
              i['state'] == kStateStandby))
        i,
  ];
  int compare(Map a, Map b) {
    final port = _number(a['systemLabel']).compareTo(_number(b['systemLabel']));
    if (port != 0) return port;
    final hw = _number(
      a['id'],
      last: true,
    ).compareTo(_number(b['id'], last: true));
    return hw != 0 ? hw : (a['id'] as String).compareTo(b['id'] as String);
  }

  MediaItem card(Map p) {
    final children = [
      for (final c in raw)
        if (c['parent'] == p['id'] && c['hidden'] != true) c,
    ];
    final device =
        p['device'] ??
        children.map((c) => c['device']).nonNulls.firstOrNull ??
        children.firstOrNull?['label'];
    return MediaItem(
      type: MediaType.input,
      id: (children.firstOrNull?['id'] ?? p['id']) as String,
      title: p['label'] as String,
      genre: device as String? ?? '',
    );
  }

  return [for (final p in ports..sort(compare)) card(p)];
}

/// The Inputs row's cards; none when the device has no inputs or the call
/// fails.
Future<List<MediaItem>> loadInputs() async {
  try {
    return visibleInputs(await Host.tvInputs());
  } catch (_) {
    return const [];
  }
}
