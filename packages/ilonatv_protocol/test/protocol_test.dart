import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:test/test.dart';

void main() {
  test('remoteKeyByName', () {
    expect(remoteKeyByName('ok'), RemoteKey.ok);
    expect(remoteKeyByName('jump'), isNull);
    expect(remoteKeyByName('volumeUp'), RemoteKey.volumeUp);
    expect(remoteKeyByName('volumeDown'), RemoteKey.volumeDown);
    expect(remoteKeyByName('playPause'), RemoteKey.playPause);
    expect(remoteKeyByName('mute'), RemoteKey.mute);
  });

  test('PairRequest round-trips', () {
    final r = PairRequest(code: '123456', name: 'Pixel');
    final back = PairRequest.fromJson(r.toJson());
    expect(back.code, '123456');
    expect(back.secret, isNull);
    expect(back.name, 'Pixel');
  });

  test('PairRequest rejects bad input', () {
    expect(() => PairRequest.fromJson({'secret': 'a', 'code': '1', 'name': 'x'}),
        throwsFormatException);
    expect(() => PairRequest.fromJson({'name': 'x'}), throwsFormatException);
    expect(() => PairRequest.fromJson({'code': '1', 'name': ''}),
        throwsFormatException);
    expect(() => PairRequest.fromJson({'code': '1', 'name': 'x' * 61}),
        throwsFormatException);
  });

  test('TvEvent survives encode/decode', () {
    final e = TvEvent('state', {'step': 'tmdb', 'inFront': true});
    final back = TvEvent.decode(e.encode());
    expect(back.type, 'state');
    expect(back.data, {'step': 'tmdb', 'inFront': true});
  });

  test('SetupStep names', () {
    expect(SetupStep.values.map((s) => s.name), [
      'welcome', 'location', 'tmdb', 'titles', 'videos', 'stremio', 'sports',
      'home', 'done',
    ]);
  });
}
