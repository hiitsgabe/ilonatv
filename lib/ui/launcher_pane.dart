import 'package:flutter/material.dart';

import '../host.dart';
import '../i18n.dart';
import '../launcher_setup.dart';
import '../settings.dart';
import 'settings_kit.dart';

/// Launcher mode: the switch, whether the accessibility service took, the
/// Fire TV fixes that need it, and what to do where Elimor may not turn the
/// service on by itself. Read again on resume, back from the system's screens.
class LauncherPane extends StatefulWidget {
  final Settings settings;
  const LauncherPane(this.settings, {super.key});

  @override
  State<LauncherPane> createState() => _LauncherPaneState();
}

class _LauncherPaneState extends State<LauncherPane> {
  late final AppLifecycleListener _lifecycle;
  LauncherSetup? _setup;
  String? _ip;

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final setup = await Host.launcherSetup();
      final ip = await deviceIp();
      if (!mounted) return;
      setState(() {
        _setup = setup;
        _ip = ip;
      });
    } catch (_) {}
  }

  Future<void> _change(VoidCallback mutate) async {
    mutate();
    await widget.settings.save();
  }

  /// Saves the switch, then enables or disables the service where Elimor
  /// may (LauncherSetup.kt); the status row shows whether it took. Where it
  /// may not, on Google TV, the system's accessibility settings open.
  Future<void> _apply(bool on) async {
    await _change(() => widget.settings.fireTvMode = on);
    await Host.setServiceEnabled(on).catchError((_) => false);
    await _load();
    final setup = _setup;
    if (setup != null &&
        launcherHint(setup, wanted: on) == LauncherHint.systemSettings) {
      await Host.openAccessibilitySettings();
    }
  }

  String _onOff(bool on) => t(on ? 'on' : 'off');

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final on = s.fireTvMode;
    final setup = _setup;
    final hint = setup == null
        ? LauncherHint.none
        : launcherHint(setup, wanted: on);
    return settingsGroups([
      SettingsGroup(
        footer: t('fireTvModeHelp'),
        children: [
          SettingsRow(
            title: t('fireTvMode'),
            value: _onOff(on),
            onPressed: () => _apply(!s.fireTvMode),
          ),
        ],
      ),
      if (setup != null)
        SettingsGroup(
          children: [
            SettingsRow(
              title: t('accessibilityService'),
              value: _onOff(setup.serviceOn),
            ),
          ],
        ),
      if (on && setup?.fireTv == true)
        SettingsGroup(
          footer: t('doublePowerFixHelp'),
          children: [
            SettingsRow(
              title: t('doublePowerFix'),
              value: _onOff(s.doublePowerFix),
              onPressed: () =>
                  _change(() => s.doublePowerFix = !s.doublePowerFix),
            ),
          ],
        ),
      if (on && setup?.fireTv == true) ...[
        SettingsGroup(
          footer: t('alexaBounceHelp'),
          children: [
            SettingsRow(
              title: t('alexaBounce'),
              value: _onOff(s.alexaBounce),
              onPressed: () => _change(() => s.alexaBounce = !s.alexaBounce),
            ),
          ],
        ),
        if (s.alexaBounce)
          SettingsGroup(
            header: t('assistantColor'),
            children: [
              _ColorRow(
                s.assistantColor,
                (c) => _change(() => s.assistantColor = c),
              ),
            ],
          ),
      ],
      if (setup != null)
        switch (hint) {
          LauncherHint.grant => SettingsGroup(
            header: t('grantOnce'),
            children: [
              // Focusable so the D-pad can scroll down to them.
              for (final command in grantCommands(_ip))
                SettingsRow(title: command, mono: true),
              SettingsRow(
                leading: const Icon(Icons.refresh),
                title: t('checkAgain'),
                onPressed: () => _apply(s.fireTvMode),
              ),
            ],
          ),
          // The row is for the way back from App info.
          LauncherHint.systemSettings => SettingsGroup(
            header: t('setup'),
            footer: setup.sdk >= 33 ? t('restrictedHint') : null,
            children: [
              SettingsRow(
                title: t('openAccessibilitySettings'),
                chevron: true,
                onPressed: Host.openAccessibilitySettings,
              ),
              if (setup.sdk >= 33)
                SettingsRow(
                  title: t('openAppInfo'),
                  chevron: true,
                  onPressed: Host.openAppInfo,
                ),
            ],
          ),
          LauncherHint.none => const SizedBox.shrink(),
        },
    ]);
  }
}

/// A row of accent colours for the assistant screen; OK picks one. The gradient
/// there is built from the single colour chosen.
class _ColorRow extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onPick;
  const _ColorRow(this.selected, this.onPick);

  static const _colors = [
    0xFF4F8CFF,
    0xFF9B6CFF,
    0xFFFF5EC7,
    0xFFFF5A4D,
    0xFFFF9F40,
    0xFF34D07A,
    0xFF2BD4C4,
    0xFFE8E8ED,
  ];

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    child: Row(
      spacing: 16,
      children: [
        for (final c in _colors)
          _Swatch(c, selected: c == selected, onPick: () => onPick(c)),
      ],
    ),
  );
}

class _Swatch extends StatefulWidget {
  final int color;
  final bool selected;
  final VoidCallback onPick;
  const _Swatch(this.color, {required this.selected, required this.onPick});

  @override
  State<_Swatch> createState() => _SwatchState();
}

class _SwatchState extends State<_Swatch> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final ring = _focused
        ? Colors.white
        : widget.selected
        ? const Color(0x80FFFFFF)
        : Colors.transparent;
    return Focus(
      autofocus: widget.selected,
      onFocusChange: (f) => setState(() => _focused = f),
      child: InkWell(
        onTap: widget.onPick,
        customBorder: const CircleBorder(),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: 44,
          height: 44,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ring, width: 3),
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color(widget.color),
            ),
          ),
        ),
      ),
    );
  }
}
