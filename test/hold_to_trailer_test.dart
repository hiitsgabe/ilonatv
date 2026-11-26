import 'package:ilonatv/hold_to_trailer.dart';
import 'package:flutter_test/flutter_test.dart';

const _ms = Duration(milliseconds: 1);

void main() {
  test('released before one second opens', () {
    final h = HoldToTrailer()..down();
    expect(h.tick(_ms * 900), HoldPhase.pressed);
    expect(h.up(_ms * 900), HoldOutcome.open);
    expect(h.phase, HoldPhase.idle);
  });

  test('held past one second counts 3, 2, 1 and releasing opens nothing', () {
    final h = HoldToTrailer()..down();
    expect(h.tick(_ms * 1000), HoldPhase.countdown);
    expect(h.secondsLeft, 3);
    h.tick(_ms * 2100);
    expect(h.secondsLeft, 2);
    h.tick(_ms * 3100);
    expect(h.secondsLeft, 1);
    expect(h.up(_ms * 3500), HoldOutcome.nothing);
  });

  test('a key in during the countdown fires once at four seconds', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1000);
    expect(h.answer(h.hold, 'KEY'), HoldPhase.countdown);
    expect(h.tick(_ms * 3900), HoldPhase.countdown);
    expect(h.tick(_ms * 4000), HoldPhase.fired);
    expect(h.key, 'KEY');
    expect(h.tick(_ms * 5000), HoldPhase.idle);
    expect(h.up(_ms * 5000), HoldOutcome.nothing);
  });

  test('a key that comes after four seconds fires then, once', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1000);
    expect(h.tick(_ms * 4200), HoldPhase.countdown);
    expect(h.secondsLeft, 1);
    expect(h.answer(h.hold, 'KEY'), HoldPhase.fired);
    expect(h.tick(_ms * 4400), HoldPhase.idle);
    expect(h.answer(h.hold, 'KEY'), HoldPhase.idle);
  });

  test('no trailer ends the countdown, and the release opens nothing', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1500);
    expect(h.answer(h.hold, null), HoldPhase.noTrailer);
    expect(h.tick(_ms * 4000), HoldPhase.noTrailer);
    expect(h.up(_ms * 4500), HoldOutcome.nothing);
  });

  test('a key after the release, or for an earlier press, does nothing', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1500);
    final first = h.hold;
    h.up(_ms * 1600);
    expect(h.answer(first, 'KEY'), HoldPhase.idle);

    h
      ..down()
      ..tick(_ms * 1500);
    expect(h.answer(first, 'OLD'), HoldPhase.countdown);
    expect(h.tick(_ms * 4000), HoldPhase.countdown, reason: 'no key yet');
  });

  test('after a fire, an answer for an earlier press is no new fire', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1500);
    final first = h.hold;
    h
      ..up(_ms * 1600)
      ..down()
      ..tick(_ms * 1000)
      ..answer(h.hold, 'KEY');
    var before = h.phase;
    expect(HoldToTrailer.firedNow(before, h.tick(_ms * 4000)), isTrue);
    before = h.phase;
    final now = h.answer(first, 'OLD');
    expect(now, HoldPhase.fired);
    expect(HoldToTrailer.firedNow(before, now), isFalse);
    expect(h.key, 'KEY');
    // The widget cancels right after the fire: nothing is left to answer.
    h.cancel();
    expect(h.answer(first, 'OLD'), HoldPhase.idle);
  });

  test(
    'a release past one second opens nothing, even before a tick saw it',
    () {
      final h = HoldToTrailer()..down();
      expect(h.up(_ms * 1100), HoldOutcome.nothing);
    },
  );

  test('a cancelled hold neither counts, fires nor opens', () {
    final h = HoldToTrailer()..down();
    h.tick(_ms * 1500);
    h.cancel();
    expect(h.phase, HoldPhase.idle);
    expect(h.answer(h.hold, 'KEY'), HoldPhase.idle);
    expect(h.tick(_ms * 4000), HoldPhase.idle);
    expect(h.up(_ms * 200), HoldOutcome.nothing);
  });
}
