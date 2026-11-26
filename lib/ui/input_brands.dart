import 'package:flutter/material.dart';

/// What an HDMI input's card shows when its HDMI-CEC name says what is plugged
/// in: the console's wordmark over its brand colours, in place of "HDMI 2".
/// Logos are Wikimedia Commons PNGs under assets/inputs/, black on
/// transparent, drawn white.
class InputBrand {
  final String asset;
  final List<Color> gradient;

  /// The logo's width as a share of the card's.
  final double width;

  /// The maker's symbol, drawn large and faint on the backdrop.
  final String mark;

  const InputBrand(
    this.asset,
    this.gradient, {
    this.width = 0.62,
    this.mark = _ps,
  });

  /// The brand named by a CEC device name ("PlayStation 4", "XBOX ONE",
  /// "NintendoSwitch"), or null for one this does not know.
  static InputBrand? of(String device) {
    final d = device.toLowerCase();
    for (final (pattern, brand) in _brands) {
      if (pattern.hasMatch(d)) return brand;
    }
    return null;
  }
}

const _ps = 'assets/inputs/playstation.png';
const _xbox = 'assets/inputs/xbox.png';
const _switch = 'assets/inputs/switch.png';

// Most specific first: "playstation 5" before "playstation".
final _brands = <(RegExp, InputBrand)>[
  (
    RegExp(r'playstation ?5|\bps5\b'),
    const InputBrand('assets/inputs/ps5.png', [
      Color(0xFF123A8F),
      Color(0xFF060C22),
    ]),
  ),
  (
    RegExp(r'playstation ?4|\bps4\b'),
    const InputBrand('assets/inputs/ps4.png', [
      Color(0xFF0A3D9E),
      Color(0xFF071634),
    ]),
  ),
  (
    RegExp(r'playstation|\bps[0-9]\b|sony'),
    const InputBrand('assets/inputs/playstation.png', [
      Color(0xFF0A3D9E),
      Color(0xFF071634),
    ], width: 0.34),
  ),
  (
    RegExp(r'xbox.*series|series ?[xs]\b'),
    const InputBrand('assets/inputs/xbox_series.png', [
      Color(0xFF1E6B1E),
      Color(0xFF07200A),
    ], mark: _xbox),
  ),
  (
    RegExp(r'xbox.*one'),
    const InputBrand('assets/inputs/xbox_one.png', [
      Color(0xFF138A13),
      Color(0xFF07260A),
    ], mark: _xbox),
  ),
  (
    RegExp(r'xbox'),
    const InputBrand(
      'assets/inputs/xbox.png',
      [Color(0xFF138A13), Color(0xFF07260A)],
      width: 0.4,
      mark: _xbox,
    ),
  ),
  (
    RegExp(r'switch ?2'),
    const InputBrand('assets/inputs/switch2.png', [
      Color(0xFFC8101E),
      Color(0xFF4A050B),
    ], mark: _switch),
  ),
  (
    RegExp(r'switch|nintendo'),
    const InputBrand('assets/inputs/switch.png', [
      Color(0xFFC8101E),
      Color(0xFF4A050B),
    ], mark: _switch),
  ),
];
