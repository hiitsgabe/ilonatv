import 'package:flutter/material.dart';
import 'package:ilonatv_protocol/releases.dart' show BadChecksum;

import '../adb.dart';
import '../desktop/platform_tools.dart';
import '../i18n.dart';
import '../tvs.dart';

/// True once adb can run ([pair]: an adb that can pair). On desktop adb is
/// Google's, which may not be passed on with this app: the first time, the
/// person agrees to Google's terms and the app downloads platform-tools.
Future<bool> ensureAdbTools(
  BuildContext context,
  Adb adb, {
  bool pair = false,
}) async {
  if (pair ? await adb.canPair() : adb.ready) return true;
  if (!context.mounted) return false;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ToolsDialog(adb),
      ) ??
      false;
}

class _ToolsDialog extends StatefulWidget {
  const _ToolsDialog(this.adb);

  final Adb adb;

  @override
  State<_ToolsDialog> createState() => _ToolsDialogState();
}

class _ToolsDialogState extends State<_ToolsDialog> {
  bool _busy = false;
  double? _progress;
  String? _error;

  Future<void> _download() async {
    setState(() {
      _busy = true;
      _progress = null;
      _error = null;
    });
    try {
      await widget.adb.download(
        progress: (got, total) {
          if (!mounted) return;
          setState(() => _progress = total > 0 ? got / total : null);
        },
      );
      if (mounted) Navigator.of(context).pop(true);
    } on BadChecksum {
      if (mounted) setState(() => _error = t('adbToolsBadChecksum'));
    } catch (_) {
      if (mounted) setState(() => _error = t('adbToolsFailed'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(t('adbToolsTitle')),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t('adbToolsBody')),
          TextButton(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => openUrl(platformToolsTerms),
            child: Text(t('adbToolsTerms')),
          ),
          if (_busy) LinearProgressIndicator(value: _progress),
          if (_error case final e?) Text(e, style: TextStyle(color: cs.error)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(t('cancel')),
        ),
        FilledButton(
          onPressed: _busy ? null : _download,
          child: Text(t('adbToolsDownload')),
        ),
      ],
    );
  }
}
