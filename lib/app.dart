import 'package:flutter/material.dart';

import 'companion/pairing.dart';
import 'settings.dart';
import 'sources.dart';
import 'store.dart';
import 'ui/home_screen.dart';
import 'ui/setup_wizard.dart';

/// Shown in Settings, under About.
const kVersion = '0.6.0';

/// The home screen's repaint boundary, which `SnapshotObserver` captures.
final homeBoundaryKey = GlobalKey();

class ElimorApp extends StatelessWidget {
  final Settings settings;
  final Sources sources;
  final Store store;
  final Pairing pairing;

  /// The app list of the last run (`apps` in [store]), for the dock's first
  /// frame.
  final Map<String, dynamic>? cachedApps;
  const ElimorApp(
    this.settings,
    this.sources,
    this.store, {
    super.key,
    required this.pairing,
    this.cachedApps,
  });

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Elimor',
    debugShowCheckedModeBanner: false,
    // A held OK presses once. Flutter's defaults repeat it, so holding OK on
    // Remove would clear row after row, and the hold that opens Settings from
    // a home tile would press whatever gets focus there.
    shortcuts: {
      for (final MapEntry(:key, :value) in WidgetsApp.defaultShortcuts.entries)
        if (key is SingleActivator && value is ActivateIntent)
          SingleActivator(key.trigger, includeRepeats: false): value
        else
          key: value,
    },
    theme: ThemeData(
      brightness: Brightness.dark,
      fontFamily: 'Inter',
      scaffoldBackgroundColor: const Color(0xFF0B0B0D),
      // Buttons are glass at rest; focused, one turns white, so focus reads
      // from the couch.
      textButtonTheme: const TextButtonThemeData(
        style: ButtonStyle(
          foregroundColor: WidgetStateColor.fromMap({
            WidgetState.focused: Colors.black,
            WidgetState.any: Colors.white,
          }),
          backgroundColor: WidgetStateColor.fromMap({
            WidgetState.focused: Colors.white,
            WidgetState.any: Color(0x26FFFFFF),
          }),
          overlayColor: WidgetStatePropertyAll(Colors.transparent),
          side: WidgetStatePropertyAll(BorderSide(color: Color(0x33FFFFFF))),
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(
              borderRadius: BorderRadius.all(Radius.circular(22)),
            ),
          ),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
    ),
    // The first run's setup until it is done; its Done swaps in the home.
    home: ListenableBuilder(
      listenable: settings,
      builder: (_, _) => settings.setupDone
          ? RepaintBoundary(
              key: homeBoundaryKey,
              child: HomeScreen(
                settings,
                sources,
                pairing: pairing,
                store: store,
                cachedApps: cachedApps,
              ),
            )
          : SetupWizard(settings, sources, pairing: pairing),
    ),
  );
}
