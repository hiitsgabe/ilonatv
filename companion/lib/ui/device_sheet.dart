import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tvs.dart';
import 'theme.dart';

enum DeviceChoice { add, forget }

/// Which TV the remote controls: a paired [Tv], or a [DeviceChoice].
Future<Object?> showDeviceSheet(
  BuildContext context, {
  required Tvs tvs,
  required Tv current,
  required Color currentDot,
  required bool canSwitch,
}) => showModalBottomSheet<Object>(
  context: context,
  builder: (_) => _DeviceSheet(
    tvs: tvs,
    current: current,
    currentDot: currentDot,
    canSwitch: canSwitch,
  ),
);

class _DeviceSheet extends StatefulWidget {
  const _DeviceSheet({
    required this.tvs,
    required this.current,
    required this.currentDot,
    required this.canSwitch,
  });

  final Tvs tvs;
  final Tv current;
  final Color currentDot;
  final bool canSwitch;

  @override
  State<_DeviceSheet> createState() => _DeviceSheetState();
}

class _DeviceSheetState extends State<_DeviceSheet> {
  // The remote holds discovery off; while choosing, the other TVs' status counts.
  @override
  void initState() {
    super.initState();
    widget.tvs.release();
  }

  @override
  void dispose() {
    widget.tvs.hold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: ListenableBuilder(
        listenable: widget.tvs,
        builder: (context, _) {
          final others = [
            if (widget.canSwitch)
              for (final tv in widget.tvs.all)
                if (tv.token != null && tv.host != widget.current.host) tv,
          ];
          Widget row(Tv tv, Color dot, bool online, {bool current = false}) =>
              ListTile(
                leading: StatusDot(dot),
                minLeadingWidth: 8,
                title: Text(
                  tv.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(t(online ? 'online' : 'offline')),
                trailing: current ? Icon(Icons.check, color: cs.primary) : null,
                onTap: () => Navigator.of(context).pop(tv),
              );
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  t('whichTv'),
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              row(
                widget.current,
                widget.currentDot,
                widget.currentDot == Tones.ok,
                current: true,
              ),
              for (final tv in others)
                row(tv, tv.found ? Tones.ok : cs.onSurfaceVariant, tv.found),
              if (widget.canSwitch)
                ListTile(
                  leading: Icon(Icons.add, color: cs.primary),
                  minLeadingWidth: 8,
                  title: Text(
                    t('addTv'),
                    style: TextStyle(
                      color: cs.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  onTap: () => Navigator.of(context).pop(DeviceChoice.add),
                ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.link_off, color: cs.error),
                minLeadingWidth: 8,
                title: Text(t('forgetTv'), style: TextStyle(color: cs.error)),
                onTap: () => Navigator.of(context).pop(DeviceChoice.forget),
              ),
            ],
          );
        },
      ),
    );
  }
}
