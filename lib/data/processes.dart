/// Settings > Processes: what `dumpsys activity processes` says each app
/// holds.
library;

/// How busy an app is, by the system's own ranking of it.
enum AppState {
  /// In front, or seen.
  open,

  /// Playing, a VPN, a keyboard: the system keeps it like the one in front.
  active,

  /// Running a service in the background.
  background,

  /// Kept only to start fast; the system drops it first.
  cached,
}

/// One app's processes together: its package, the memory they hold and the
/// busiest state among them.
typedef AppMemory = ({String package, int kb, AppState state});

/// What Settings > Processes shows: the apps, the most memory first, and the
/// device's free and total RAM in kB.
typedef Meminfo = ({List<AppMemory> apps, int freeKb, int totalKb});

final _record = RegExp(
  r'^\s*\*(APP|PERS)\* UID (\d+) ProcessRecord\{\w+ \d+:([^/\s]+)/([^}\s]+)\}',
);
// Sizes may come with a decimal comma in a Portuguese system.
final _pss = RegExp(r'\blastPss=([\d.,]+)(KB|MB|GB)?');
// Android 9 writes `oom: max=…`, 14 `oom adj: max=…`.
final _adj = RegExp(r'\boom(?: adj)?: max=-?\d+ .*?\bcur=(-?\d+)');

/// An isolated process (a WebView renderer, `u0a231i12`) and its app's user
/// (`u0a231`).
final _isolated = RegExp(r'^(u\d+a\d+)i\d+$');

int _toKb(String n, String? unit) =>
    (double.parse(n.replaceAll(',', '.')) *
            switch (unit) {
              'GB' => 1024 * 1024,
              'MB' => 1024,
              _ => 1,
            })
        .round();

/// The state of an `oom_adj`: 0 in front, 100 seen, 200 perceptible, 300–400
/// backup and heavy (which the system will not close from here either), 500
/// and 800 services, 600 the home, 700 the previous app, 900 on cached.
AppState? _stateOf(int adj) => switch (adj) {
  < 0 => null, // the system's own
  <= 100 => AppState.open,
  < 500 => AppState.active,
  < 600 || >= 800 && < 900 => AppState.background,
  _ => AppState.cached,
};

/// The apps of a `dumpsys activity processes` text: each process's last
/// measured memory (`lastPss`) counted to its package (`com.stremio.one:
/// server` is Stremio's, a WebView renderer the app it renders for), the
/// busiest state among them. Persistent processes and those of system users
/// (UID under 10000) are the system's and are left out. Null when the text is
/// no such dump (dumpsys refused: no DUMP permission).
List<AppMemory>? parseProcesses(String text) {
  final lines = text.split('\n');
  if (!lines.any(_record.hasMatch)) return null;
  final records = <({String package, String user, int kb, AppState state})>[];
  ({String package, String user})? current;
  int? kb;
  for (final l in lines) {
    if (_record.firstMatch(l) case final m?) {
      final app = m.group(1) == 'APP' && int.parse(m.group(2)!) >= 10000;
      current = app
          ? (package: m.group(3)!.split(':').first, user: m.group(4)!)
          : null;
      kb = null;
    } else if (l.contains('ProcessRecord{')) {
      current = null; // a list of records, not a record
    } else if (_pss.firstMatch(l) case final m? when current != null) {
      kb = _toKb(m.group(1)!, m.group(2));
    } else if (_adj.firstMatch(l) case final m? when current != null) {
      final state = _stateOf(int.parse(m.group(1)!));
      if (kb != null && state != null) {
        records.add((
          package: current.package,
          user: current.user,
          kb: kb,
          state: state,
        ));
      }
      current = null;
    }
  }
  final byUser = {
    for (final r in records)
      if (!_isolated.hasMatch(r.user)) r.user: r.package,
  };
  final apps = <String, AppMemory>{};
  for (final r in records) {
    final owner = _isolated.firstMatch(r.user)?.group(1);
    final package = (owner == null ? null : byUser[owner]) ?? r.package;
    final had = apps[package];
    apps[package] = (
      package: package,
      kb: (had?.kb ?? 0) + r.kb,
      // A renderer's rank is its app's, not its own.
      state: owner != null && had != null
          ? had.state
          : had == null || r.state.index < had.state.index
          ? r.state
          : had.state,
    );
  }
  return apps.values.toList()..sort((a, b) => b.kb.compareTo(a.kb));
}
