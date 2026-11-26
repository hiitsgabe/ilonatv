import 'package:elimor_protocol/elimor_protocol.dart';
import 'package:flutter/services.dart';

import 'launcher_setup.dart';

/// [tv]: it has a TV (`LEANBACK_LAUNCHER`) activity. [system]: it came with
/// the device and was never updated. Unknown, both read false, so the app
/// shows.
class InstalledApp {
  final String package;
  final String label;
  final bool tv;
  final bool system;
  const InstalledApp(
    this.package,
    this.label, {
    this.tv = false,
    this.system = false,
  });

  /// The shape the channel's `listApps` answers in, and the home's cache.
  Map<String, Object> toJson() => {
    'package': package,
    'label': label,
    'tv': tv,
    'system': system,
  };

  factory InstalledApp.fromJson(Map json) => InstalledApp(
    json['package'] as String,
    json['label'] as String,
    tv: json['tv'] == true,
    system: json['system'] == true,
  );
}

/// The apps Elimor offers, in [apps] order: those with a TV activity and those
/// the user installed, minus [hidden]. A system app with only a phone launcher
/// activity (Fire OS has dozens) never shows.
Map<String, InstalledApp> offeredApps(
  Map<String, InstalledApp> apps, [
  Set<String> hidden = const {},
]) => {
  for (final MapEntry(:key, :value) in apps.entries)
    if ((value.tv || !value.system) && !hidden.contains(key)) key: value,
};

/// Android-side services behind the `app.elimor/host` channel (HostChannel.kt).
class Host {
  static const _channel = MethodChannel('app.elimor/host');

  static void Function()? _goHome;
  static void Function()? _inputsChanged;
  static Future<List<Map<String, Object?>>> Function(
    String type,
    String query,
    String what,
  )?
  _assistantSearch;

  static Future<bool> Function(String type, String id)? _assistantOpen;

  static void _listen() => _channel.setMethodCallHandler((call) async {
    if (call.method == 'goHome') _goHome?.call();
    if (call.method == 'inputsChanged') _inputsChanged?.call();
    if (call.method == 'assistantSearch') {
      final a = call.arguments as Map;
      return _assistantSearch?.call(
            a['type'] as String,
            a['query'] as String,
            a['what'] as String? ?? '',
          ) ??
          const [];
    }
    if (call.method == 'assistantOpen') {
      final a = call.arguments as Map;
      return await _assistantOpen?.call(
            a['type'] as String,
            a['id'] as String,
          ) ??
          false;
    }
    return null;
  });

  /// OK on an assistant hit that the Dart side opens as the home does:
  /// [type] 'games' with the game's id, or 'movie' or 'series' with the
  /// title's TMDB id. True when something opened.
  static set onAssistantOpen(Future<bool> Function(String type, String id) f) {
    _assistantOpen = f;
    _listen();
  }

  /// The voice assistant (Assistant.kt) asking one of the home's sources:
  /// [type] 'youtube' for now. Each hit is a map of title, sub, poster, uri,
  /// webUri and package, as the overlay's cards and OK need them.
  static set onAssistantSearch(
    Future<List<Map<String, Object?>>> Function(
      String type,
      String query,
      String what,
    )
    f,
  ) {
    _assistantSearch = f;
    _listen();
  }

  /// Called when Android sends Elimor back to its home screen: Home pressed,
  /// or the Fire TV curtain relaunching it (MainActivity.onNewIntent).
  static set onGoHome(void Function() f) {
    _goHome = f;
    _listen();
  }

  /// Called, while Elimor is in front, when an HDMI input comes, goes or
  /// changes state (MainActivity.onResume).
  static set onInputsChanged(void Function()? f) {
    _inputsChanged = f;
    _listen();
  }

  static void goHome() => _goHome?.call();

  /// Sends [key] into Elimor's window; false when no activity is resumed.
  static Future<bool> injectKey(RemoteKey key) async {
    if (key == RemoteKey.home) {
      goHome();
      return true;
    }
    return _bool('injectKey', {'key': key.name});
  }

  static Future<void> advertise(int port, String name) =>
      _channel.invokeMethod<void>('advertise', {'port': port, 'name': name});

  static Future<void> unadvertise() =>
      _channel.invokeMethod<void>('unadvertise');

  static Future<bool> _bool(String method, [Object? args]) async =>
      await _channel.invokeMethod<bool>(method, args) ?? false;

  static Future<List<InstalledApp>> listApps() async {
    final apps = await _channel.invokeListMethod<Map>('listApps') ?? const [];
    return [for (final a in apps) InstalledApp.fromJson(a)];
  }

  /// Packages of the apps that open [uri], Elimor aside.
  static Future<List<String>> appsFor(String uri) async =>
      await _channel.invokeListMethod<String>('appsFor', {'uri': uri}) ??
      const [];

  /// PNG of the app's banner, else its icon; null if the package is missing.
  static Future<Uint8List?> appIcon(String package) =>
      _channel.invokeMethod<Uint8List>('appIcon', {'package': package});

  /// Content URIs of the pictures on the device, newest first; null when
  /// Elimor may not read them. The first call asks the user.
  static Future<List<String>?> images() =>
      _channel.invokeListMethod<String>('images');

  /// A small JPEG or PNG of the picture at [uri]; null if it does not read.
  static Future<Uint8List?> imageThumb(String uri) =>
      _channel.invokeMethod<Uint8List>('imageThumb', {'uri': uri});

  /// Copies the picture at [uri] into Elimor's files, scaled down to a tile's
  /// size; the copy's path, null if it does not read.
  static Future<String?> copyImage(String uri) =>
      _channel.invokeMethod<String>('copyImage', {'uri': uri});

  /// Every TV input as Android describes it (HostChannel.tvInputs);
  /// `visibleInputs` picks the cards. None on a device without TV inputs.
  static Future<List<Map>> tvInputs() async =>
      await _channel.invokeListMethod<Map>('tvInputs') ?? const [];

  /// Shows the input [id] full screen, with [noSignal] while nothing comes
  /// in; false when it cannot open.
  static Future<bool> openInput(String id, {String? noSignal}) =>
      _bool('openInput', {'id': id, 'noSignal': noSignal});

  static Future<bool> launch(String package) =>
      _bool('launch', {'package': package});

  /// Opens [uri] in the Stremio app [package] and, with the accessibility
  /// service on and [package] the build whose views it knows (HomeWatcher.kt),
  /// taps its first stream once the page lists them.
  static Future<bool> openStremioAndPlay(String uri, String package) =>
      _bool('openStremioAndPlay', {'uri': uri, 'package': package});

  static Future<bool> open(String uri, {String? package}) =>
      _bool('open', {'uri': uri, 'package': package});

  static Future<LauncherSetup> launcherSetup() async {
    final m =
        await _channel.invokeMapMethod<String, Object?>('launcherSetup') ??
        const {};
    return LauncherSetup(
      fireTv: m['fireTv'] == true,
      serviceOn: m['serviceOn'] == true,
      sdk: m['sdk'] as int? ?? 0,
    );
  }

  /// Adds Elimor's accessibility service to the system's list or takes it
  /// out; false without WRITE_SECURE_SETTINGS.
  static Future<bool> setServiceEnabled(bool on) =>
      _bool('setServiceEnabled', {'on': on});

  static Future<void> openAccessibilitySettings() =>
      _channel.invokeMethod<void>('openAccessibilitySettings');

  /// Elimor's App info screen, where Android 13+ allows restricted settings.
  static Future<void> openAppInfo() =>
      _channel.invokeMethod<void>('openAppInfo');

  /// A settings screen: Fire OS's own page [component]
  /// (`package/.Activity`), else the screen of [action] (the system's
  /// settings by default). [pause] stops Launcher mode from taking the Amazon
  /// home's settings tab for a Home until Home is pressed.
  static Future<bool> openSystemSettings({
    String? component,
    String? action,
    bool pause = false,
  }) => _bool('openSystemSettings', {
    'component': component,
    'action': action,
    'pause': pause,
  });

  static Future<int> processMemoryKb() async =>
      await _channel.invokeMethod<int>('processMemoryKb') ?? 0;

  /// The device's RAM in kB (ActivityManager totalMem); 0 when unknown.
  static Future<int> deviceMemoryKb() async =>
      await _channel.invokeMethod<int>('deviceMemoryKb') ?? 0;

  /// The activity manager's process records as text (dumpsys's refusal
  /// without the DUMP permission) and the device's available and total
  /// memory in kB.
  static Future<({String dump, int availKb, int totalKb})> processes() async {
    final m = await _channel.invokeMapMethod<String, Object?>('processes');
    return (
      dump: m?['dump'] as String? ?? '',
      availKb: (m?['availKb'] as num?)?.toInt() ?? 0,
      totalKb: (m?['totalKb'] as num?)?.toInt() ?? 0,
    );
  }

  /// The packages never to force stop: those with an accessibility service on
  /// and the keyboard.
  static Future<Set<String>> keepRunning() async => {
    ...?await _channel.invokeListMethod<String>('keepRunning'),
  };

  /// Closes [package]'s processes that are in the background.
  static Future<bool> killBackground(String package) =>
      _bool('killBackground', {'package': package});

  /// Force stop on [package]'s settings page, clicked by the accessibility
  /// service; false without it.
  static Future<bool> forceStop(String package) =>
      _bool('forceStop', {'package': package});

  /// The app's private files directory (`Context.filesDir`), where the disk
  /// cache lives.
  static Future<String> filesDir() async =>
      (await _channel.invokeMethod<String>('filesDir'))!;

  /// The home as last drawn, as raw RGBA pixels of [width] × [height], for
  /// the curtain (Curtain.kt).
  static Future<void> setSnapshot(Uint8List rgba, int width, int height) =>
      _channel.invokeMethod<void>('setSnapshot', {
        'rgba': rgba,
        'width': width,
        'height': height,
      });
}
