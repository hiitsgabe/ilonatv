import 'package:flutter/material.dart';

/// The TV's default accent; a TV that says which one it uses replaces it.
const kDefaultAccent = Color(0xFF4F8CFF);

final accent = ValueNotifier<Color>(kDefaultAccent);

/// Colours the scheme has no slot for.
abstract final class Tones {
  static const ok = Color(0xFF3CCF7D);
  static const warnContainer = Color(0xFF3A2C14);
  static const onWarnContainer = Color(0xFFFFE0B2);
}

ThemeData companionTheme(Color seed) {
  final cs = ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark)
      .copyWith(
        surface: const Color(0xFF0F1115),
        surfaceContainerLowest: const Color(0xFF0B0D10),
        surfaceContainerLow: const Color(0xFF171A20),
        surfaceContainer: const Color(0xFF1D2128),
        surfaceContainerHigh: const Color(0xFF252A33),
        surfaceContainerHighest: const Color(0xFF2E3440),
        onSurface: const Color(0xFFE6E8EF),
        onSurfaceVariant: const Color(0xFFA7ADBB),
        outline: const Color(0xFF3A404C),
        outlineVariant: const Color(0xFF2E3440),
        errorContainer: const Color(0xFF4A1E1A),
        onErrorContainer: const Color(0xFFFFDAD5),
      );
  const label = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);
  const shape = StadiumBorder();
  return ThemeData(
    useMaterial3: true,
    colorScheme: cs,
    fontFamily: 'Inter',
    scaffoldBackgroundColor: cs.surface,
    appBarTheme: AppBarTheme(
      backgroundColor: cs.surface,
      surfaceTintColor: Colors.transparent,
      scrolledUnderElevation: 0,
    ),
    cardTheme: CardThemeData(
      color: cs.surfaceContainer,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: shape,
        textStyle: label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 52),
        shape: shape,
        textStyle: label,
        side: BorderSide(color: cs.outline),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(shape: shape, textStyle: label),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: cs.surfaceContainerLow,
      indicatorColor: cs.primaryContainer,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: cs.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: cs.outline,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(26)),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: cs.surfaceContainerHighest,
      contentTextStyle: TextStyle(color: cs.onSurface, fontFamily: 'Inter'),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: cs.surfaceContainerHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
    ),
    dividerTheme: DividerThemeData(color: cs.outline),
  );
}

enum StripKind { info, warn, error }

/// The one line under the top bar that says what needs attention.
class Strip extends StatelessWidget {
  const Strip({
    super.key,
    required this.kind,
    required this.icon,
    required this.text,
    this.sub,
    this.action,
  });

  final StripKind kind;
  final IconData icon;
  final String text;
  final String? sub;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg, iconColor) = switch (kind) {
      StripKind.info => (cs.surfaceContainerHigh, cs.onSurface, cs.primary),
      StripKind.warn => (
        Tones.warnContainer,
        Tones.onWarnContainer,
        Tones.onWarnContainer,
      ),
      StripKind.error => (cs.errorContainer, cs.onErrorContainer, cs.error),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(color: fg, fontWeight: FontWeight.w600),
                ),
                if (sub != null)
                  Text(sub!, style: TextStyle(color: fg, fontSize: 13)),
              ],
            ),
          ),
          if (action != null)
            TextButtonTheme(
              data: TextButtonThemeData(
                style: TextButton.styleFrom(foregroundColor: fg),
              ),
              child: action!,
            ),
        ],
      ),
    );
  }
}

class StatusDot extends StatelessWidget {
  const StatusDot(this.color, {super.key});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(color: color, shape: BoxShape.circle),
  );
}
