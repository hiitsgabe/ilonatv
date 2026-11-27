import 'package:flutter/material.dart';

import '../i18n.dart';
import '../tv_client.dart';
import 'theme.dart';

bool isSetupStep(String? step) => step == 'tmdb' || step == 'location';

/// Every kind of typing for the TV, in one sheet: the setup step it is on,
/// else whatever field has focus there.
Future<void> showKeyboardSheet(
  BuildContext context, {
  required TvClient client,
  required String? step,
  required Future<void> Function(TvResult) onResult,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => KeyboardSheet(client: client, step: step, onResult: onResult),
);

class KeyboardSheet extends StatelessWidget {
  const KeyboardSheet({
    super.key,
    required this.client,
    required this.step,
    required this.onResult,
  });

  final TvClient client;
  final String? step;
  final Future<void> Function(TvResult) onResult;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t('typeOnTv'),
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (isSetupStep(step))
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    t(step == 'tmdb' ? 'setupTmdb' : 'setupCity'),
                    style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13),
                  ),
                ),
              const SizedBox(height: 14),
              if (step == 'tmdb')
                TmdbForm(client: client, onResult: onResult)
              else if (step == 'location')
                CityForm(client: client, onResult: onResult)
              else
                TextForm(client: client, onResult: onResult),
            ],
          ),
        ),
      ),
    );
  }
}

class TextForm extends StatefulWidget {
  const TextForm({super.key, required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<TextForm> createState() => _TextFormState();
}

class _TextFormState extends State<TextForm> {
  // As the TV caps it.
  static const _max = 500;
  final _text = TextEditingController();
  String? _why;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _why = null;
    });
    final nav = Navigator.of(context);
    final r = await widget.client.text(_text.text);
    if (!mounted) return;
    if (r is Ok) {
      nav.pop();
      return;
    }
    setState(() {
      _busy = false;
      _why = switch (r) {
        Refused(error: 'noField') => t('noField'),
        Refused(status: 404) => t('textNeedsUpdate'),
        _ => t('cantReach'),
      };
    });
    if (r is! Refused) await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      TextField(
        controller: _text,
        autofocus: true,
        maxLength: _max,
        textInputAction: TextInputAction.send,
        onSubmitted: (_) => _send(),
        decoration: InputDecoration(hintText: t('typeHint'), counterText: ''),
      ),
      if (_why != null)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Strip(
            kind: StripKind.warn,
            icon: Icons.keyboard_outlined,
            text: _why!,
          ),
        ),
      const SizedBox(height: 10),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t('cancel')),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: _busy ? null : _send,
            icon: const Icon(Icons.send, size: 18),
            label: Text(t('send')),
          ),
        ],
      ),
    ],
  );
}

class TmdbForm extends StatefulWidget {
  const TmdbForm({super.key, required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<TmdbForm> createState() => _TmdbFormState();
}

class _TmdbFormState extends State<TmdbForm> {
  final _key = TextEditingController();
  String? _message;
  bool _busy = false;
  bool _hidden = true;

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _run(bool save) async {
    final k = _key.text.trim();
    if (k.isEmpty || _busy) return;
    setState(() => _busy = true);
    final r = await widget.client.setupTmdb(k, save: save);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = switch (r) {
        Ok(value: 'keyOk') when save => t('keySaved'),
        Ok(:final value) => t(value),
        Unreachable() || Refused() => t('networkError'),
        _ => null,
      };
    });
    if (r is! Ok) await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      TextField(
        controller: _key,
        autofocus: true,
        autocorrect: false,
        enableSuggestions: false,
        obscureText: _hidden,
        decoration: InputDecoration(
          labelText: t('tmdbKey'),
          suffixIcon: IconButton(
            icon: Icon(_hidden ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _hidden = !_hidden),
          ),
        ),
      ),
      if (_message != null)
        Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!)),
      const SizedBox(height: 8),
      Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: _busy ? null : () => _run(false),
            child: Text(t('test')),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _busy ? null : () => _run(true),
            child: Text(t('save')),
          ),
        ],
      ),
    ],
  );
}

class CityForm extends StatefulWidget {
  const CityForm({super.key, required this.client, required this.onResult});

  final TvClient client;
  final Future<void> Function(TvResult) onResult;

  @override
  State<CityForm> createState() => _CityFormState();
}

class _CityFormState extends State<CityForm> {
  final _q = TextEditingController();
  List<Place>? _places;
  bool _busy = false;
  String? _set;

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _q.text.trim();
    if (q.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _set = null;
    });
    final r = await widget.client.cities(q);
    if (!mounted) return;
    setState(() => _busy = false);
    if (r is Ok<List<Place>>) {
      setState(() => _places = r.value);
    } else {
      await widget.onResult(r);
    }
  }

  Future<void> _pick(Place p) async {
    final r = await widget.client.setCity(p);
    if (mounted && r is Ok) {
      setState(() {
        _places = null;
        _set = p.name;
      });
    }
    await widget.onResult(r);
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      TextField(
        controller: _q,
        autofocus: true,
        textInputAction: TextInputAction.search,
        onSubmitted: (_) => _search(),
        decoration: InputDecoration(
          labelText: t('city'),
          hintText: t('searchCity'),
          suffixIcon: IconButton(
            icon: const Icon(Icons.search),
            onPressed: _search,
          ),
        ),
      ),
      if (_busy)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(),
        )
      else if (_places?.isEmpty ?? false)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t('noResults')),
        )
      else if (_set case final city?)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(t('citySet').replaceAll('{city}', city)),
        ),
      ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 220),
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final p in _places ?? const <Place>[])
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                leading: const Icon(Icons.place_outlined),
                title: Text(p.name),
                subtitle: Text(
                  [p.region, p.country].where((s) => s.isNotEmpty).join(', '),
                ),
                onTap: () => _pick(p),
              ),
          ],
        ),
      ),
    ],
  );
}
