import 'package:flutter/material.dart';

/// The pieces of Settings, copied from tvOS: a small title centred on top, a
/// big glass tile with an icon on the left, and on the right a list of thin
/// rows that turn white with focus.

const _rest = Color(0x14FFFFFF);
const _text = Color(0xE6FFFFFF);
const _dim = Color(0x80FFFFFF);
const _dimOnWhite = Color(0x8C000000);
const _radius = BorderRadius.all(Radius.circular(8));

/// Help text, under a group or wherever a screen explains itself.
const settingsNote = TextStyle(fontSize: 13, height: 1.35, color: _dim);

/// The height of a row: 62 px at 1080p, as tvOS's.
const settingsRowHeight = 31.0;

/// After this frame, when nothing in [context]'s page has focus, its first
/// row takes it. A list that comes late calls it from its own build.
void focusFirstRow(BuildContext context) =>
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted) return;
      final scope = FocusScope.of(context);
      if (FocusManager.instance.primaryFocus == scope) scope.nextFocus();
    });

/// A screen of Settings: [title] over all, [icon] in the tile on the left
/// (cross-fading when it changes) and [child], the list, on the right,
/// centred when it fits and scrolling when not. When nothing in it has focus
/// (just pushed, or its content came late), the first row takes it.
class SettingsPage extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  const SettingsPage({
    super.key,
    required this.title,
    required this.icon,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    focusFirstRow(context);
    final size = MediaQuery.sizeOf(context);
    final side = 0.44 * size.height;
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF17171B), Color(0xFF0B0B0D)],
          ),
        ),
        child: Column(
          children: [
            SizedBox(height: 0.045 * size.height),
            Text(
              title,
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Color(0x99FFFFFF),
              ),
            ),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: 0.54 * size.width,
                    child: Center(child: _Hero(icon, side)),
                  ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, box) => SingleChildScrollView(
                        // Room for a focused row's growth and shadow.
                        padding: const EdgeInsets.fromLTRB(8, 16, 8, 24),
                        child: ConstrainedBox(
                          constraints: BoxConstraints(
                            minHeight: box.maxHeight - 40,
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [child],
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 0.05 * size.width),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens a [SettingsPage] whose [title] and list [build] makes, again
/// whenever [listen] changes (the language among others).
Future<void> pushSettingsPage(
  BuildContext context, {
  required String Function() title,
  required IconData icon,
  required Listenable listen,
  required Widget Function() build,
}) => Navigator.of(context).push(
  MaterialPageRoute<void>(
    builder: (_) => ListenableBuilder(
      listenable: listen,
      builder: (_, _) =>
          SettingsPage(title: title(), icon: icon, child: build()),
    ),
  ),
);

/// The rounded square of frosted glass with the screen's icon.
class _Hero extends StatelessWidget {
  final IconData icon;
  final double side;
  const _Hero(this.icon, this.side);

  @override
  Widget build(BuildContext context) => Container(
    width: side,
    height: side,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.all(Radius.circular(0.14 * side)),
      gradient: const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0x4DFFFFFF), Color(0x2EFFFFFF)],
      ),
      border: Border.all(color: const Color(0x1FFFFFFF)),
      boxShadow: const [
        BoxShadow(
          color: Color(0x59000000),
          blurRadius: 40,
          offset: Offset(0, 16),
        ),
      ],
    ),
    child: Center(
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 150),
        child: Icon(
          icon,
          key: ValueKey(icon),
          size: 0.45 * side,
          color: const Color(0x8CFFFFFF),
        ),
      ),
    ),
  );
}

/// A screen's groups, one under the other, 16 dp apart.
Widget settingsGroups(List<Widget> groups) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  spacing: 16,
  children: groups,
);

/// Rows 4 dp apart, with a small [header] over them and a [footer], the help
/// text, under them.
class SettingsGroup extends StatelessWidget {
  final String? header;
  final String? footer;
  final List<Widget> children;
  const SettingsGroup({
    super.key,
    this.header,
    this.footer,
    required this.children,
  });

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 4,
    children: [
      if (header case final h?)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 2),
          child: Text(h, style: settingsNote),
        ),
      ...children,
      if (footer case final f?)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Text(f, style: settingsNote),
        ),
    ],
  );
}

/// Whether the row around is white, so its small buttons draw dark.
class _OnWhite extends InheritedWidget {
  final bool value;
  const _OnWhite(this.value, {required super.child});

  @override
  bool updateShouldNotify(_OnWhite old) => old.value != value;
}

/// A row of tvOS's list: [leading] (24 dp), [title], then on the right a dim
/// [value] or [valueIcon] and a chevron when it opens something. With focus
/// it turns white with black text and grows a little over a soft shadow.
/// Every row takes focus; without [onPressed], OK does nothing. [extras],
/// small round buttons after the value, take focus of their own: Right moves
/// into them. [mono] is for commands: small monospace text that wraps.
/// [primary] is the one to press: brighter at rest, its title bold.
class SettingsRow extends StatefulWidget {
  final String title;
  final String? value;
  final IconData? valueIcon;
  final Widget? leading;
  final bool chevron;
  final bool mono;
  final bool primary;
  final VoidCallback? onPressed;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final List<Widget> extras;

  const SettingsRow({
    super.key,
    required this.title,
    this.value,
    this.valueIcon,
    this.leading,
    this.chevron = false,
    this.mono = false,
    this.primary = false,
    this.onPressed,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.extras = const [],
  });

  @override
  State<SettingsRow> createState() => _SettingsRowState();
}

class _SettingsRowState extends State<SettingsRow> {
  var _focused = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final fg = _focused ? Colors.black : _text;
    final dim = _focused ? _dimOnWhite : _dim;
    final content = Row(
      spacing: 10,
      children: [
        if (w.leading case final l?)
          SizedBox.square(
            dimension: 24,
            child: IconTheme.merge(
              data: IconThemeData(size: 20, color: fg),
              child: l,
            ),
          ),
        Expanded(
          child: w.mono
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    w.title,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                      color: fg,
                    ),
                  ),
                )
              : Text(
                  w.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    color: fg,
                    fontWeight: w.primary ? FontWeight.w600 : null,
                  ),
                ),
        ),
        if (w.value case final v?)
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(
              v,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 15, color: dim),
            ),
          ),
        if (w.valueIcon case final i?) Icon(i, size: 18, color: fg),
        if (w.chevron)
          Icon(
            Icons.chevron_right,
            size: 18,
            color: _focused ? _dimOnWhite : const Color(0x66FFFFFF),
          ),
      ],
    );
    final button = TextButton(
      focusNode: w.focusNode,
      autofocus: w.autofocus,
      onFocusChange: (focused) {
        setState(() => _focused = focused);
        w.onFocusChange?.call(focused);
      },
      onPressed: w.onPressed ?? () {},
      style: const ButtonStyle(
        // The box around draws the row.
        backgroundColor: WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStatePropertyAll(BorderSide.none),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(borderRadius: _radius),
        ),
        padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 16)),
        minimumSize: WidgetStatePropertyAll(Size(0, settingsRowHeight)),
        alignment: Alignment.centerLeft,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      child: content,
    );
    return AnimatedScale(
      scale: _focused ? 1.03 : 1,
      duration: const Duration(milliseconds: 120),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: _focused
              ? Colors.white
              : w.primary
              ? const Color(0x33FFFFFF)
              : _rest,
          borderRadius: _radius,
          boxShadow: _focused
              ? const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 18,
                    offset: Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: w.extras.isEmpty
            ? button
            : _OnWhite(
                _focused,
                child: Row(
                  spacing: 6,
                  children: [
                    Expanded(child: button),
                    ...w.extras,
                    const SizedBox(width: 2),
                  ],
                ),
              ),
      ),
    );
  }
}

/// A 26 dp round button with [icon], for a row's [SettingsRow.extras];
/// [label] says what it does.
class RoundIconButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onPressed;
  final FocusNode? focusNode;

  const RoundIconButton(
    this.icon, {
    super.key,
    required this.label,
    required this.onPressed,
    this.focusNode,
  });

  @override
  Widget build(BuildContext context) {
    final onWhite =
        context.dependOnInheritedWidgetOfExactType<_OnWhite>()?.value ?? false;
    return Semantics(
      label: label,
      child: TextButton(
        focusNode: focusNode,
        onPressed: onPressed,
        style: ButtonStyle(
          shape: const WidgetStatePropertyAll(CircleBorder()),
          side: const WidgetStatePropertyAll(BorderSide.none),
          fixedSize: const WidgetStatePropertyAll(Size.square(26)),
          minimumSize: const WidgetStatePropertyAll(Size.square(26)),
          padding: const WidgetStatePropertyAll(EdgeInsets.zero),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          backgroundColor: WidgetStateColor.fromMap({
            WidgetState.focused: Colors.white,
            WidgetState.any: onWhite
                ? const Color(0x14000000)
                : const Color(0x1FFFFFFF),
          }),
          foregroundColor: WidgetStateColor.fromMap({
            WidgetState.focused: Colors.black,
            WidgetState.any: onWhite ? _dimOnWhite : const Color(0xB3FFFFFF),
          }),
        ),
        child: Icon(icon, size: 16),
      ),
    );
  }
}
