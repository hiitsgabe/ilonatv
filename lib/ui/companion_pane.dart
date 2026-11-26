import 'dart:math';

import 'package:ilonatv_protocol/ilonatv_protocol.dart' show kCompanionPort;
import 'package:flutter/material.dart';

import '../companion/pairing.dart';
import '../i18n.dart';
import 'qr_code.dart';
import 'settings_kit.dart';

/// Settings > Companion: the QR a phone opens Ilona TV's page with, the code
/// the Companion app pairs with, and the paired devices. [compact] is the
/// setup's welcome step: the QR and the code only. The code pairs only while
/// one of these is on screen.
class CompanionPane extends StatefulWidget {
  final Pairing pairing;

  /// The TV's address; null when it is on no network.
  final String? address;
  final bool compact;
  const CompanionPane(
    this.pairing,
    this.address, {
    super.key,
    this.compact = false,
  });

  @override
  State<CompanionPane> createState() => _CompanionPaneState();
}

class _CompanionPaneState extends State<CompanionPane> {
  late final AppLifecycleListener _lifecycle;
  final _newQr = FocusNode();
  final _rows = <String, FocusNode>{};

  @override
  void initState() {
    super.initState();
    widget.pairing.offerCode();
    _lifecycle = AppLifecycleListener(
      onResume: widget.pairing.offerCode,
      onPause: widget.pairing.withdrawCode,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    widget.pairing.withdrawCode();
    _newQr.dispose();
    for (final n in _rows.values) {
      n.dispose();
    }
    super.dispose();
  }

  /// Focus, whose button goes, lands on the row that took this one's place,
  /// the one above, or New QR: never on another Remove, which OK would press.
  Future<void> _remove(String token) async {
    final p = widget.pairing;
    final i = p.settings.companionDevices.keys.toList().indexOf(token);
    // A second OK while the first remove is still saving.
    if (i < 0) return;
    await p.remove(token);
    final left = p.settings.companionDevices.keys.toList();
    final next = left.isEmpty ? _newQr : _rows[left[min(i, left.length - 1)]];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rows.remove(token)?.dispose();
      if (mounted && next?.context != null) next!.requestFocus();
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.pairing,
    builder: (context, _) {
      final p = widget.pairing;
      final ip = widget.address;
      final compact = widget.compact;
      final code = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compact)
            Text(
              t('setupFromPhone'),
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
            ),
          Text(t('pairCode'), style: settingsNote),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              p.code,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: compact ? 28 : 34,
                fontWeight: FontWeight.w600,
                letterSpacing: 4,
              ),
            ),
          ),
          if (ip == null) Text(t('noNetwork'), style: settingsNote),
        ],
      );
      final top = Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          spacing: 20,
          children: [
            if (ip != null)
              QrCode(
                'http://$ip:$kCompanionPort/#s=${p.secret}',
                size: compact ? 160 : 180,
              ),
            Flexible(child: code),
          ],
        ),
      );
      if (compact) return top;
      final devices = p.settings.companionDevices;
      return settingsGroups([
        top,
        if (ip != null)
          SettingsGroup(
            footer: t('companionHelp'),
            children: [
              SettingsRow(
                title: t('newQr'),
                valueIcon: Icons.refresh,
                focusNode: _newQr,
                onPressed: p.renewSecret,
              ),
            ],
          ),
        if (devices.isNotEmpty)
          SettingsGroup(
            header: t('pairedDevices'),
            children: [
              for (final MapEntry(key: token, value: name) in devices.entries)
                SettingsRow(
                  key: ValueKey(token),
                  title: name,
                  focusNode: _rows.putIfAbsent(token, FocusNode.new),
                  extras: [
                    RoundIconButton(
                      Icons.delete_outline,
                      label: t('remove'),
                      onPressed: () => _remove(token),
                    ),
                  ],
                ),
            ],
          ),
      ]);
    },
  );
}
