import 'dart:convert';

const kCompanionPort = 8642;
const kProtocolVersion = 1;
const kServiceType = '_ilonatv._tcp';

enum RemoteKey { up, down, left, right, ok, back, home, volumeUp, volumeDown, playPause }

RemoteKey? remoteKeyByName(String name) {
  for (final k in RemoteKey.values) {
    if (k.name == name) return k;
  }
  return null;
}

// Same names as the wizard's steps in lib/ui/setup_wizard.dart.
enum SetupStep { welcome, location, tmdb, titles, videos, stremio, sports, home, done }

class PairRequest {
  final String? secret;
  final String? code;
  final String name;

  PairRequest({this.secret, this.code, required this.name});

  Map<String, dynamic> toJson() => {
        if (secret != null) 'secret': secret,
        if (code != null) 'code': code,
        'name': name,
      };

  factory PairRequest.fromJson(Map json) {
    final secret = json['secret'];
    final code = json['code'];
    final name = json['name'];
    if (secret != null && secret is! String ||
        code != null && code is! String ||
        name is! String) {
      throw const FormatException('bad pair request');
    }
    if ((secret == null) == (code == null)) {
      throw const FormatException('need exactly one of secret or code');
    }
    if (name.isEmpty || name.length > 60) {
      throw const FormatException('bad name');
    }
    return PairRequest(secret: secret as String?, code: code as String?, name: name);
  }
}

class TvEvent {
  final String type;
  final Map<String, dynamic> data;

  const TvEvent(this.type, [this.data = const {}]);

  String encode() => jsonEncode({'type': type, 'data': data});

  static TvEvent decode(String s) {
    final j = jsonDecode(s);
    if (j is! Map || j['type'] is! String) {
      throw const FormatException('bad event');
    }
    final d = j['data'];
    return TvEvent(j['type'] as String, d is Map ? Map<String, dynamic>.from(d) : {});
  }
}
