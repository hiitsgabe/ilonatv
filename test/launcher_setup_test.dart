import 'package:ilonatv/launcher_setup.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const fire = LauncherSetup(fireTv: true, serviceOn: false, sdk: 28);
  const google = LauncherSetup(fireTv: false, serviceOn: false, sdk: 34);

  test('nothing to do while the switch is off or the service is on', () {
    expect(launcherHint(fire, wanted: false), LauncherHint.none);
    expect(
      launcherHint(
        LauncherSetup(fireTv: true, serviceOn: true, sdk: 28),
        wanted: true,
      ),
      LauncherHint.none,
    );
  });
  test('Fire TV wants the one-time grant, Google TV the system screens', () {
    expect(launcherHint(fire, wanted: true), LauncherHint.grant);
    expect(launcherHint(google, wanted: true), LauncherHint.systemSettings);
  });
  test('the grant commands connect to the TV, then grant to IlonaTv', () {
    expect(grantCommands('10.0.0.5'), [
      'adb connect 10.0.0.5:5555',
      'adb -s 10.0.0.5:5555 shell pm grant tv.ilona.app android.permission.WRITE_SECURE_SETTINGS',
      'adb -s 10.0.0.5:5555 shell pm grant tv.ilona.app android.permission.DUMP',
      'adb -s 10.0.0.5:5555 shell pm grant tv.ilona.app android.permission.PACKAGE_USAGE_STATS',
    ]);
    expect(grantCommands(null), [
      'adb connect <tv-ip>:5555',
      'adb -s <tv-ip>:5555 shell pm grant tv.ilona.app android.permission.WRITE_SECURE_SETTINGS',
      'adb -s <tv-ip>:5555 shell pm grant tv.ilona.app android.permission.DUMP',
      'adb -s <tv-ip>:5555 shell pm grant tv.ilona.app android.permission.PACKAGE_USAGE_STATS',
    ]);
  });
}
