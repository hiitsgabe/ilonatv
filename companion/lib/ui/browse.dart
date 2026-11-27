import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tv_client.dart';
import 'title_sheet.dart';

/// Search and the TV's rows in one: the rows while the field is empty.
class ExploreTab extends StatefulWidget {
  const ExploreTab({
    super.key,
    required this.client,
    required this.onResult,
    required this.tvLabel,
    this.onWatched,
  });

  final TvClient client;
  final Future<void> Function(TvResult) onResult;
  final String tvLabel;
  final VoidCallback? onWatched;

  @override
  State<ExploreTab> createState() => _ExploreTabState();
}

enum _Filter { all, movies, series, videos }

class _ExploreTabState extends State<ExploreTab> {
  final _field = TextEditingController();
  Timer? _debounce;
  SearchResults? _results;
  String _q = '';
  bool _busy = false;
  _Filter _filter = _Filter.all;
  List<TvRow>? _rows;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _field.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await widget.client.rows();
    if (!mounted) return;
    if (r is Ok<List<TvRow>>) {
      setState(() {
        _rows = r.value;
        _failed = false;
      });
    } else {
      if (_rows == null) setState(() => _failed = true);
      await widget.onResult(r);
    }
  }

  void _changed(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() {
        _q = '';
        _results = null;
        _busy = false;
        _filter = _Filter.all;
      });
      return;
    }
    setState(() {});
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(q));
  }

  Future<void> _run(String q) async {
    setState(() {
      _q = q;
      _busy = true;
    });
    final r = await widget.client.search(q);
    if (!mounted || q != _q) return;
    setState(() => _busy = false);
    if (r is Ok<SearchResults>) {
      setState(() => _results = r.value);
    } else {
      await widget.onResult(r);
    }
  }

  void _show(Item i) => showTitleSheet(
    context,
    i,
    widget.client,
    widget.onResult,
    tvLabel: widget.tvLabel,
    onWatched: widget.onWatched,
  );

  Widget _section(String title, List<Item> items) {
    final wide = isWide(items.first);
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(child: _RowTitle(title)),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: SliverLayoutBuilder(
            builder: (context, c) {
              final cols = wide ? 2 : (c.crossAxisExtent > 600 ? 4 : 3);
              final w = (c.crossAxisExtent - 12 * (cols - 1)) / cols;
              return SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  mainAxisExtent: posterHeight(context, items.first, w),
                ),
                itemCount: items.length,
                itemBuilder: (_, i) => Poster(
                  item: items[i],
                  width: w,
                  onTap: () => _show(items[i]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _found(SearchResults r) {
    final sections = [
      (_Filter.movies, t('movies'), r.movies),
      (_Filter.series, t('series'), r.series),
      (_Filter.videos, t('youtube'), r.videos),
    ].where((s) => s.$3.isNotEmpty).toList();
    if (sections.isEmpty) return Center(child: Text(t('noResults')));
    final shown = sections.where(
      (s) => _filter == _Filter.all || s.$1 == _filter,
    );
    return Column(
      children: [
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            children: [
              for (final (f, label) in [
                (_Filter.all, t('filterAll')),
                for (final s in sections) (s.$1, s.$2),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: FilterChip(
                    key: Key('filter-${f.name}'),
                    label: Text(label),
                    selected: _filter == f,
                    showCheckmark: false,
                    onSelected: (_) => setState(() => _filter = f),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              for (final s in shown) _section(s.$2, s.$3),
              const SliverToBoxAdapter(child: SizedBox(height: 24)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _browse() {
    final rows = _rows;
    if (rows == null && _failed) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(t('loadFailed')),
            const SizedBox(height: 8),
            FilledButton.tonalIcon(
              onPressed: () {
                setState(() => _failed = false);
                _load();
              },
              icon: const Icon(Icons.refresh),
              label: Text(t('retry')),
            ),
          ],
        ),
      );
    }
    if (rows == null) return const Center(child: CircularProgressIndicator());
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.all(32),
              child: Center(child: Text(t('noResults'))),
            ),
          for (final row in rows)
            if (row.items.isNotEmpty) ...[
              _RowTitle(row.title),
              SizedBox(
                height: row.items
                    .map((i) => posterHeight(context, i, posterWidth(i)))
                    .reduce((a, b) => a > b ? a : b),
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: row.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 10),
                  itemBuilder: (_, i) => Poster(
                    item: row.items[i],
                    width: posterWidth(row.items[i]),
                    onTap: () => _show(row.items[i]),
                  ),
                ),
              ),
            ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _results;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _field,
            onChanged: _changed,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t('searchHint'),
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _field.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: t('clear'),
                      icon: const Icon(Icons.close),
                      onPressed: () {
                        _field.clear();
                        _changed('');
                      },
                    ),
              border: const OutlineInputBorder(
                borderRadius: BorderRadius.all(Radius.circular(999)),
                borderSide: BorderSide.none,
              ),
            ),
          ),
        ),
        if (_busy)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: LinearProgressIndicator(),
          ),
        Expanded(
          child: _q.isEmpty
              ? _browse()
              : r == null
              ? const SizedBox.shrink()
              : _found(r),
        ),
      ],
    );
  }
}

class _RowTitle extends StatelessWidget {
  const _RowTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
    child: Text(
      text,
      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
    ),
  );
}
