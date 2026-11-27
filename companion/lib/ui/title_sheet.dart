import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tv_client.dart';
import 'theme.dart';

String? _s(Item i, String k) {
  final v = i[k];
  return v is String && v.isNotEmpty ? v : null;
}

bool isWide(Item i) => i['type'] == 'video';

double posterWidth(Item i) => isWide(i) ? 240 : 110;

double posterHeight(BuildContext context, Item i, double width) {
  final label = MediaQuery.textScalerOf(context).scale(13) * 1.5;
  return (isWide(i) ? width * 9 / 16 : width * 1.5) + 6 + label;
}

class Poster extends StatelessWidget {
  const Poster({
    super.key,
    required this.item,
    required this.width,
    this.onTap,
  });

  final Item item;
  final double width;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final wide = isWide(item);
    final url = wide
        ? (_s(item, 'backdropUrl') ?? _s(item, 'posterUrl'))
        : _s(item, 'posterUrl');
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final cs = Theme.of(context).colorScheme;
    final placeholder = Container(
      color: cs.surfaceContainerHigh,
      alignment: Alignment.center,
      child: Icon(Icons.movie_outlined, color: cs.onSurfaceVariant),
    );
    return SizedBox(
      width: width,
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: AspectRatio(
                aspectRatio: wide ? 16 / 9 : 2 / 3,
                child: url == null
                    ? placeholder
                    : Image.network(
                        url,
                        fit: BoxFit.cover,
                        cacheWidth: (width * dpr).round(),
                        errorBuilder: (_, _, _) => placeholder,
                      ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _s(item, 'title') ?? '',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> showTitleSheet(
  BuildContext context,
  Item item,
  TvClient client,
  Future<void> Function(TvResult) onResult,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => TitleSheet(item: item, client: client, onResult: onResult),
);

class TitleSheet extends StatefulWidget {
  const TitleSheet({
    super.key,
    required this.item,
    required this.client,
    required this.onResult,
  });

  final Item item;
  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<TitleSheet> createState() => _TitleSheetState();
}

class _TitleSheetState extends State<TitleSheet> {
  bool _busy = false;
  bool _failed = false;

  Future<void> _watch() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _failed = false;
    });
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    final r = await widget.client.open(widget.item);
    if (r is Ok<bool> && !r.value) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failed = true;
        });
      }
      return;
    }
    if (r is Ok<bool>) {
      messenger.showSnackBar(SnackBar(content: Text(t('openingOnTv'))));
    }
    // Only this sheet's own route: if it was dismissed meanwhile, a pop would close the remote.
    if (mounted) nav.pop();
    await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) {
    final i = widget.item;
    final image = _s(i, 'backdropUrl') ?? _s(i, 'posterUrl');
    final meta = [
      if (i['year'] != null) '${i['year']}',
      ?_s(i, 'genre'),
      if (i['rating'] is num) '★ ${(i['rating'] as num).toStringAsFixed(1)}',
    ].join('  ·  ');
    final w = MediaQuery.sizeOf(context).width;
    final cs = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (image != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Image.network(
                    image,
                    fit: BoxFit.cover,
                    cacheWidth: (w * MediaQuery.devicePixelRatioOf(context))
                        .round(),
                    errorBuilder: (_, _, _) =>
                        Container(color: cs.surfaceContainerHigh),
                  ),
                ),
              ),
            const SizedBox(height: 16),
            Text(
              _s(i, 'title') ?? '',
              style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
            ),
            if (_s(i, 'subtitle') != null)
              Text(
                _s(i, 'subtitle')!,
                style: TextStyle(color: cs.onSurfaceVariant),
              ),
            if (meta.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(meta, style: TextStyle(color: cs.onSurfaceVariant)),
              ),
            if (_s(i, 'overview') != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  _s(i, 'overview')!,
                  style: TextStyle(height: 1.4, color: cs.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 20),
            if (_failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Strip(
                  key: const Key('cantOpen'),
                  kind: StripKind.error,
                  icon: Icons.error_outline,
                  text: t('cantOpen'),
                ),
              ),
            SizedBox(
              width: double.infinity,
              height: 54,
              child: FilledButton.icon(
                key: const Key('watch'),
                onPressed: _busy ? null : _watch,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.tv),
                label: Text(
                  t('watchOnTv'),
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
