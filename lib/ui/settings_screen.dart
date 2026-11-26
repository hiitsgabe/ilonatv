import 'package:flutter/material.dart';

import '../app.dart';
import '../companion/pairing.dart';
import '../host.dart';
import '../i18n.dart';
import '../launcher_setup.dart';
import '../providers.dart';
import '../settings.dart';
import '../sources.dart';
import 'companion_pane.dart';
import 'launcher_pane.dart';
import 'processes_pane.dart';
import 'settings_kit.dart';
import 'settings_panes.dart';
import 'setup_wizard.dart';
import 'sports_pane.dart';

// Each is an i18n key and names its screen; in groups, a gap between them.
const _groups = [
  [
    ('rowsConfig', Icons.view_agenda_outlined),
    ('weather', Icons.wb_sunny_outlined),
    ('sports', Icons.sports_soccer_outlined),
  ],
  [
    ('apps', Icons.apps),
    ('providers', Icons.open_in_new),
    ('processes', Icons.memory),
  ],
  // One group with the TV's own rows: a group more and the list scrolls at
  // 1080p.
  [
    ('accounts', Icons.person_outline),
    ('companion', Icons.phone_iphone),
    ('fireTvMode', Icons.home_outlined),
    ('language', Icons.language),
    ('systemSettings', Icons.settings_outlined),
    ('about', Icons.info_outline),
  ],
];

/// tvOS's Settings: the sections in a list, each with its value; OK opens a
/// section's screen, Back comes back. The tile on the left shows the focused
/// section's icon.
class SettingsScreen extends StatefulWidget {
  final Settings settings;
  final Sources sources;
  final Pairing pairing;
  const SettingsScreen(
    this.settings,
    this.sources, {
    super.key,
    required this.pairing,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final AppLifecycleListener _lifecycle;

  /// Ticks when something read from the platform arrives, so open screens
  /// redraw with it.
  final _loaded = ValueNotifier(0);
  var _icon = _groups.first.first.$2;
  // Null until the platform answers.
  Map<String, InstalledApp>? _apps;
  // The apps that open Stremio's links; null until the platform answers.
  List<String>? _stremioApps;
  LauncherSetup? _setup;
  String? _ip;
  var _ipKnown = false;
  int? _memoryKb;

  late final _listen = Listenable.merge([widget.settings, _loaded]);

  @override
  void initState() {
    super.initState();
    // Back from the system's screens, the screen shows what changed there.
    _lifecycle = AppLifecycleListener(onResume: _loadSetup);
    _loadApps();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _loaded.dispose();
    super.dispose();
  }

  void _set(VoidCallback f) {
    if (!mounted) return;
    setState(f);
    _loaded.value++;
  }

  Future<void> _loadApps() async {
    final apps = await Host.listApps().catchError((_) => <InstalledApp>[]);
    _set(() => _apps = {for (final a in apps) a.package: a});
    final stremio = await Host.appsFor(kStremioProbe)
        .catchError((_) => <String>[]);
    _set(() => _stremioApps = stremio);
  }

  Future<void> _loadSetup() async {
    try {
      final setup = await Host.launcherSetup();
      final ip = await deviceIp();
      _set(() {
        _setup = setup;
        _ip = ip;
      });
    } catch (_) {}
  }

  Future<void> _loadIp() async {
    final ip = await deviceIp();
    _set(() {
      _ip = ip;
      _ipKnown = true;
    });
  }

  Future<void> _loadMemory() async {
    try {
      final kb = await Host.processMemoryKb();
      _set(() => _memoryKb = kb);
    } catch (_) {}
  }

  /// Fire OS has no settings screen of its own: its grid is a tab of the
  /// Amazon home. So the pages that open from outside come first, and the
  /// grid last, with Launcher mode paused until Home.
  Widget _systemSettingsPane() {
    Widget row(String key, VoidCallback onPressed) =>
        SettingsRow(title: t(key), chevron: true, onPressed: onPressed);
    // Nothing until the device is known: a Fire TV must not get the unpaused
    // grid from the Google TV button.
    final setup = _setup;
    if (setup == null) return const SizedBox.shrink();
    if (!setup.fireTv) {
      return SettingsGroup(
        children: [row('systemSettings', Host.openSystemSettings)],
      );
    }
    const p = 'com.amazon.tv.settings.v2/.tv';
    return SettingsGroup(
      footer: t('sysAllHint'),
      children: [
        for (final (key, component) in const [
          ('sysNetwork', '$p.network.NetworkActivity'),
          ('sysApps', '$p.applications.ApplicationsActivity'),
          (
            'sysControllers',
            '$p.controllers_bluetooth_devices.ControllersAndBluetoothActivity',
          ),
          ('sysDevice', '$p.device.DeviceActivity'),
        ])
          row(key, () => Host.openSystemSettings(component: component)),
        row(
          'sysAccessibility',
          () => Host.openSystemSettings(
            action: 'android.settings.ACCESSIBILITY_SETTINGS',
          ),
        ),
        row('sysAll', () => Host.openSystemSettings(pause: true)),
      ],
    );
  }

  String _onOff(bool on) => t(on ? 'on' : 'off');

  /// Rows to read, focusable so Back and the D-pad have somewhere to be.
  Widget _aboutPane() {
    String mb(int bytes) => '${(bytes / (1 << 20)).toStringAsFixed(1)} MB';
    return settingsGroups([
      SettingsGroup(
        children: [
          SettingsRow(title: t('version'), value: kVersion),
          if (_memoryKb case final kb?) ...[
            SettingsRow(title: t('memory'), value: mb(kb * 1024)),
            SettingsRow(
              title: t('imageCache'),
              value:
                  '${mb(imageCache.currentSizeBytes)} · '
                  '${imageCache.liveImageCount} ${t('images')}',
            ),
          ],
        ],
      ),
      SettingsGroup(
        children: [
          SettingsRow(
            title: t('runSetup'),
            chevron: true,
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => SetupWizard(
                  widget.settings,
                  widget.sources,
                  pairing: widget.pairing,
                ),
              ),
            ),
          ),
        ],
      ),
      SettingsGroup(
        footer: t('attribution'),
        children: [SettingsRow(title: t('licence'), value: 'GPL-3.0-only')],
      ),
      // TMDB's terms ask for its logo, less prominent than the app's own.
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Image.asset(
            'assets/brand/tmdb.png',
            height: 9,
            semanticLabel: 'TMDB',
          ),
        ),
      ),
    ]);
  }

  Widget _pane(String key) {
    final apps = _apps;
    final sources = widget.sources;
    return switch (key) {
      'rowsConfig' when apps != null => RowsPane(widget.settings, apps),
      'apps' when apps != null => AppsPane(widget.settings, apps),
      'providers' when apps != null => ProvidersPane(widget.settings, apps),
      'processes' when apps != null => ProcessesPane(
        // The apps a person knows, not Fire OS's phone-launcher ones.
        offeredApps(apps),
        grant: grantCommands(_ip),
      ),
      'companion' when _ipKnown => CompanionPane(widget.pairing, _ip),
      'rowsConfig' ||
      'apps' ||
      'processes' ||
      'providers' ||
      'companion' => const SizedBox(),
      'accounts' => AccountsPane(
        widget.settings,
        sources,
        stremioApps: _stremioApps ?? const [],
      ),
      'weather' => WeatherPane(widget.settings, sources.weather),
      'sports' => SportsPane(widget.settings),
      'fireTvMode' => LauncherPane(widget.settings),
      'language' => LanguagePane(widget.settings, sources),
      'systemSettings' => _systemSettingsPane(),
      _ => _aboutPane(),
    };
  }

  /// Screens that show live values read them each time they open.
  void _open(String key, IconData icon) {
    if (key == 'fireTvMode' || key == 'systemSettings') _loadSetup();
    if (key == 'about') _loadMemory();
    if (key == 'companion') _loadIp();
    pushSettingsPage(
      context,
      title: () => t(key),
      icon: icon,
      listen: _listen,
      build: () => _pane(key),
    );
  }

  String? _value(String key) {
    final s = widget.settings;
    return switch (key) {
      'rowsConfig' => t(
        'nOn',
      ).replaceAll('{n}', '${s.homeRows.where((r) => r.on).length}'),
      'weather' => s.weatherCity,
      'sports' => s.sports.isEmpty ? t('off') : '${s.sports.length}',
      'accounts' =>
        '${s.youtubeAccounts.length + (s.stremioAuthKey.isEmpty ? 0 : 1) + (s.tmdbKey.isEmpty ? 0 : 1) + (s.alexaBounce && s.geminiKey.isNotEmpty ? 1 : 0)}',
      'companion' => '${s.companionDevices.length}',
      'fireTvMode' => _onOff(s.fireTvMode),
      'language' => kLanguageNames[s.language],
      'about' => kVersion,
      _ => null,
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.settings,
    builder: (context, _) => SettingsPage(
      title: t('settings'),
      icon: _icon,
      child: settingsGroups([
        for (final group in _groups)
          SettingsGroup(
            children: [
              for (final (key, icon) in group)
                SettingsRow(
                  title: t(key),
                  value: _value(key),
                  chevron: true,
                  autofocus: key == _groups.first.first.$1,
                  onFocusChange: (focused) {
                    if (focused) setState(() => _icon = icon);
                  },
                  onPressed: () => _open(key, icon),
                ),
            ],
          ),
      ]),
    ),
  );
}
