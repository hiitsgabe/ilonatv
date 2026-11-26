/// Where a press of OK on a card is: [pressed] for its first second, then
/// [countdown] to the trailer, [fired] once it is due and its key is known,
/// [noTrailer] when the title turned out to have none.
enum HoldPhase { idle, pressed, countdown, fired, noTrailer }

/// What a release of OK does: open the card, or nothing (it was held).
enum HoldOutcome { open, nothing }

/// OK on a card: released within [countdownAt] it opens the card; held on, it
/// counts 3, 2, 1 while the trailer's key is asked for ([answer]), and fires at
/// [fireAt] once the key is in, or as soon as it comes after that. Times are how
/// long OK has been down, as the caller measures it.
class HoldToTrailer {
  static const countdownAt = Duration(seconds: 1);
  static const fireAt = Duration(seconds: 4);

  HoldPhase phase = HoldPhase.idle;

  /// What the countdown shows, 3 to 1.
  int secondsLeft = 3;

  /// Which press this is: an answer for an earlier one is dropped.
  int get hold => _hold;
  var _hold = 0;

  /// The trailer's key, once [answer] gave one for this press.
  String? get key => _key;
  String? _key;

  /// [fireAt] went by before the key was in.
  var _due = false;

  void down() {
    _hold++;
    _key = null;
    _due = false;
    phase = HoldPhase.pressed;
  }

  /// The phase after OK has been down for [held]. [HoldPhase.fired] comes once:
  /// the tick after it is idle.
  HoldPhase tick(Duration held) {
    switch (phase) {
      case HoldPhase.fired:
        phase = HoldPhase.idle;
      case HoldPhase.pressed || HoldPhase.countdown:
        if (held >= fireAt) {
          _due = true;
          secondsLeft = 1;
          phase = _key == null ? HoldPhase.countdown : HoldPhase.fired;
        } else if (held >= countdownAt) {
          phase = HoldPhase.countdown;
          secondsLeft = ((fireAt - held).inSeconds + 1).clamp(1, 3);
        }
      case HoldPhase.idle || HoldPhase.noTrailer:
        break;
    }
    return phase;
  }

  /// The trailer's [key] for press [hold], null when there is none. Dropped
  /// unless that press is still counting down. Fires when [fireAt] already went
  /// by.
  HoldPhase answer(int hold, String? key) {
    if (hold != _hold || phase != HoldPhase.countdown) return phase;
    if (key == null) return phase = HoldPhase.noTrailer;
    _key = key;
    if (_due) phase = HoldPhase.fired;
    return phase;
  }

  /// Opens only a press released within [countdownAt], even when no tick has
  /// seen it pass.
  HoldOutcome up(Duration held) {
    final open = phase == HoldPhase.pressed && held < countdownAt;
    phase = HoldPhase.idle;
    return open ? HoldOutcome.open : HoldOutcome.nothing;
  }

  void cancel() => phase = HoldPhase.idle;

  /// Whether going from [before] to [now] is the fire: a phase that stays
  /// [HoldPhase.fired], as on an answer for an earlier press, is not.
  static bool firedNow(HoldPhase before, HoldPhase now) =>
      before != HoldPhase.fired && now == HoldPhase.fired;
}
