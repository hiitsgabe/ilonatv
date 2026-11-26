import 'dart:io';

import 'package:elimor/data/processes.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parseProcesses: the apps of the TV\'s dump, by package, the most '
      'memory first; persistent processes left out', () {
    final apps = parseProcesses(
      File('test/fixtures/dumpsys_activity_processes.txt').readAsStringSync(),
    )!;
    final byPackage = {for (final a in apps) a.package: a};
    expect(byPackage['com.example.vpn'], (
      package: 'com.example.vpn',
      kb: 167 * 1024,
      state: AppState.open,
    ));
    expect(byPackage['com.amazon.tv.ime']!.state, AppState.active);
    expect(byPackage['com.amazon.venezia'], (
      package: 'com.amazon.venezia',
      kb: 18 * 1024,
      state: AppState.cached,
    ));
    expect(byPackage['com.amazon.tv.launcher']!.state, AppState.cached);
    // *PERS*: the system's.
    expect(byPackage, isNot(contains('com.amazon.vizzini')));
    expect(byPackage, isNot(contains('system')));
    final sizes = [for (final a in apps) a.kb];
    expect(sizes, [...sizes]..sort((a, b) => b.compareTo(a)));
  });

  test('parseProcesses: processes of one package add up, as the busiest; '
      'units and the PID list read right', () {
    final apps = parseProcesses('''
  *APP* UID 10001 ProcessRecord{a 1:com.example.vpn/u0a1}
    adjSeq=1 lruSeq=0 lastPss=50MB lastSwapPss=0.00
    oom: max=1001 curRaw=200 setRaw=200 cur=200 set=200
  *APP* UID 10002 ProcessRecord{b 2:com.stremio.one:stremio_server_process/u0a2}
    adjSeq=1 lruSeq=0 lastPss=1.5GB lastSwapPss=0.00
    oom: max=1001 curRaw=500 setRaw=500 cur=500 set=500
  *APP* UID 10002 ProcessRecord{c 3:com.stremio.one/u0a2}
    adjSeq=1 lruSeq=0 lastPss=512KB lastSwapPss=0.00
    oom: max=1001 curRaw=905 setRaw=905 cur=905 set=905
  *PERS* UID 3 ProcessRecord{d 4:com.android.se/1068}
    adjSeq=1 lruSeq=0 lastPss=2.0MB lastSwapPss=0.00
    oom: max=-800 curRaw=-800 setRaw=-800 cur=-800 set=-800
    PID #1: ProcessRecord{a 1:com.example.vpn/u0a1}
    lastPss=999MB
    oom: max=0 cur=0
''')!;
    expect(apps, [
      (
        package: 'com.stremio.one',
        kb: 1536 * 1024 + 512,
        state: AppState.background,
      ),
      (package: 'com.example.vpn', kb: 50 * 1024, state: AppState.active),
    ]);
  });

  test('parseProcesses: a WebView renderer counts to its app; a decimal '
      'comma reads; system users and adj 300-499 as the system ranks them', () {
    expect(
      parseProcesses('''
  *APP* UID 10231 ProcessRecord{a 1:com.example.recorder/u0a231}
    lastPss=40,5MB lastSwapPss=0.00
    oom: max=1001 curRaw=0 setRaw=0 cur=0 set=0
  *APP* UID 99012 ProcessRecord{b 2:com.amazon.webview.chromium:sandboxed_process0/u0a231i12}
    lastPss=85MB lastSwapPss=0.00
    oom: max=1001 curRaw=900 setRaw=900 cur=900 set=900
  *APP* UID 1000 ProcessRecord{c 3:com.mediatek.tvinput/1000}
    lastPss=5MB lastSwapPss=0.00
    oom: max=1001 curRaw=905 setRaw=905 cur=905 set=905
  *APP* UID 10050 ProcessRecord{d 4:com.example.backup/u0a50}
    lastPss=1MB lastSwapPss=0.00
    oom: max=1001 curRaw=300 setRaw=300 cur=300 set=300
'''),
      [
        (
          package: 'com.example.recorder',
          kb: 40 * 1024 + 512 + 85 * 1024,
          state: AppState.open,
        ),
        (package: 'com.example.backup', kb: 1024, state: AppState.active),
      ],
    );
  });

  test('parseProcesses: Android 14 says "oom adj"', () {
    expect(
      parseProcesses('''
  *APP* UID 10156 ProcessRecord{66cfe7b 31817:com.google.android.youtube/u0a156}
    lastPss=109MB lastSwapPss=26MB lastCachedPss=109MB lastCachedSwapPss=26MB lastRss=190MB
    oom adj: max=1001 curRaw=905 setRaw=905 cur=905 set=905
'''),
      [
        (
          package: 'com.google.android.youtube',
          kb: 109 * 1024,
          state: AppState.cached,
        ),
      ],
    );
  });

  test('parseProcesses: a refusal is no dump', () {
    expect(
      parseProcesses(
        'Permission Denial: can\'t dump ActivityManager from from pid=1, '
        'uid=10243 without permission android.permission.DUMP',
      ),
      isNull,
    );
  });
}
