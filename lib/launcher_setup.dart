import 'dart:io';

/// What Launcher mode needs from the device, as `LauncherSetup.kt` reads it.
class LauncherSetup {
  /// An Amazon device: Fire OS lists no third-party accessibility service, so
  /// only Elimor itself can enable it, after [grantCommands].
  final bool fireTv;

  /// Elimor's accessibility service is in the system's enabled list.
  final bool serviceOn;

  /// `Build.VERSION.SDK_INT`.
  final int sdk;

  const LauncherSetup({
    required this.fireTv,
    required this.serviceOn,
    required this.sdk,
  });
}

/// What the Launcher mode pane offers under the status line.
enum LauncherHint { none, grant, systemSettings }

/// [wanted] is the Launcher mode switch.
LauncherHint launcherHint(LauncherSetup s, {required bool wanted}) {
  if (!wanted || s.serviceOn) return LauncherHint.none;
  return s.fireTv ? LauncherHint.grant : LauncherHint.systemSettings;
}

/// What a computer on the same network runs once so Elimor may enable its own
/// service; typed there, so shown as is and never translated. [ip] is the TV's
/// address, `<tv-ip>` when unknown. `-s` keeps the grant on the TV when the
/// computer has other devices attached.
List<String> grantCommands(String? ip) {
  final tv = '${ip ?? '<tv-ip>'}:5555';
  return [
    'adb connect $tv',
    'adb -s $tv shell pm grant app.elimor.app '
        'android.permission.WRITE_SECURE_SETTINGS',
    // Settings > Processes reads what each app holds: the activity manager's
    // dump wants both.
    'adb -s $tv shell pm grant app.elimor.app android.permission.DUMP',
    'adb -s $tv shell pm grant app.elimor.app '
        'android.permission.PACKAGE_USAGE_STATS',
  ];
}

/// The TV's IPv4 address, for [grantCommands]: the first one of the first
/// interface that is not loopback; null when there is none.
Future<String?> deviceIp() async {
  try {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    return interfaces.firstOrNull?.addresses.firstOrNull?.address;
  } catch (_) {
    return null;
  }
}
