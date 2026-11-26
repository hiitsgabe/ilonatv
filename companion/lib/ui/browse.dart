import 'dart:async';

import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tv_client.dart';
import 'title_sheet.dart';

class SearchTab extends StatefulWidget {
  const SearchTab({super.key, required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<SearchTab> createState() => _SearchTabState();
}

class _SearchTabState extends State<SearchTab> {
  Timer? _debounce;
  SearchResults? _results;
  String _q = '';

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _changed(String v) {
    _debounce?.cancel();
    final q = v.trim();
    if (q.isEmpty) {
      setState(() {
        _q = '';
        _results = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _run(q));
  }

  Future<void> _run(String q) async {
    _q = q;
    final r = await widget.client.search(q);
    if (!mounted || q != _q) return;
    if (r is Ok<SearchResults>) {
      setState(() => _results = r.value);
    } else {
      await widget.onResult(r);
    }
  }

  Widget _section(String title, List<Item> items) {
    final wide = items.isNotEmpty && items.first['type'] == 'video';
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
          ),
        ),
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
                  mainAxisExtent: (wide ? w * 9 / 16 : w * 1.5) + 30,
                ),
                itemCount: items.length,
                itemBuilder: (_, i) => Poster(
                  item: items[i],
                  width: w,
                  onTap: () => showTitleSheet(
                    context,
                    items[i],
                    widget.client,
                    widget.onResult,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = _results;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: TextField(
            onChanged: _changed,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: t('searchHint'),
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
        ),
        Expanded(
          child: r == null
              ? const SizedBox.shrink()
              : (r.movies.isEmpty && r.series.isEmpty && r.videos.isEmpty)
              ? Center(child: Text(t('noResults')))
              : CustomScrollView(
                  slivers: [
                    if (r.movies.isNotEmpty) _section(t('movies'), r.movies),
                    if (r.series.isNotEmpty) _section(t('series'), r.series),
                    if (r.videos.isNotEmpty) _section(t('youtube'), r.videos),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
        ),
      ],
    );
  }
}

class BrowseTab extends StatefulWidget {
  const BrowseTab({super.key, required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<BrowseTab> createState() => _BrowseTabState();
}

class _BrowseTabState extends State<BrowseTab> {
  List<TvRow>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await widget.client.rows();
    if (!mounted) return;
    if (r is Ok<List<TvRow>>) {
      setState(() => _rows = r.value);
    } else {
      await widget.onResult(r);
    }
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
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
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  row.title,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              SizedBox(
                height:
                    (row.items.first['type'] == 'video'
                        ? 160 * 9 / 16
                        : 160 * 1.5) +
                    34,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: row.items.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 12),
                  itemBuilder: (_, i) => Poster(
                    item: row.items[i],
                    width: row.items[i]['type'] == 'video' ? 240 : 110,
                    onTap: () => showTitleSheet(
                      context,
                      row.items[i],
                      widget.client,
                      widget.onResult,
                    ),
                  ),
                ),
              ),
            ],
        ],
      ),
    );
  }
}
