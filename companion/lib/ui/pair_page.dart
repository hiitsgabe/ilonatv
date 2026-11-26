import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:ilonatv_protocol/ilonatv_protocol.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../i18n.dart';
import '../tv_client.dart';
import '../tvs.dart';
import 'remote_page.dart';

({String host, int port, String secret})? parsePairUrl(String s) {
  final u = Uri.tryParse(s.trim());
  if (u == null || u.scheme != 'http' || u.host.isEmpty) return null;
  final m = RegExp(r'^s=([^&]+)').firstMatch(u.fragment);
  if (m == null) return null;
  return (host: u.host, port: u.hasPort ? u.port : kCompanionPort, secret: m.group(1)!);
}

final _hostRe = RegExp(
  r'^(\d{1,3}(\.\d{1,3}){3}|[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*)$',
);

({String host, int? port})? parseHostInput(String input) {
  final s = input.trim();
  final i = s.lastIndexOf(':');
  final host = i < 0 ? s : s.substring(0, i);
  final port = i < 0 ? null : int.tryParse(s.substring(i + 1));
  if (!_hostRe.hasMatch(host)) return null;
  if (i >= 0 && (port == null || port < 1 || port > 65535)) return null;
  if (RegExp(r'^\d+(\.\d+){3}$').hasMatch(host) &&
      host.split('.').any((o) => int.parse(o) > 255)) {
    return null;
  }
  return (host: host, port: port);
}

typedef ClientFor = TvClient Function(Tv tv);

class PairPage extends StatefulWidget {
  const PairPage({super.key, required this.tvs, required this.clientFor, this.host});

  final Tvs tvs;
  final ClientFor clientFor;
  final String? host;

  @override
  State<PairPage> createState() => _PairPageState();
}

class _PairPageState extends State<PairPage> {
  late final _host = TextEditingController(text: widget.host);
  final _code = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _host.dispose();
    _code.dispose();
    super.dispose();
  }

  Tv _tvFor(String host, [int? port]) {
    for (final t in widget.tvs.all) {
      if (t.host == host) return t;
    }
    return Tv(host: host, port: port ?? kCompanionPort, name: host);
  }

  Future<String> _deviceName() async {
    try {
      return await const MethodChannel('tv.ilona.companion/host')
              .invokeMethod<String>('deviceName') ??
          'Phone';
    } on PlatformException {
      return 'Phone';
    } on MissingPluginException {
      return 'Phone';
    }
  }

  Future<void> _pair(Tv tv, {String? code, String? secret}) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = widget.clientFor(tv);
    final r = await client.pair(code: code, secret: secret, name: await _deviceName());
    if (!mounted) return;
    switch (r) {
      case Ok(:final value):
        await widget.tvs.savePaired(tv, value);
        if (!mounted) return;
        final paired = _tvFor(tv.host, tv.port);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => RemotePage(tv: paired, client: widget.clientFor(paired)),
          ),
        );
      case Unpaired():
        setState(() {
          _busy = false;
          _error = t('badCode');
        });
      default:
        setState(() {
          _busy = false;
          _error = t('cantReach');
        });
    }
  }

  Future<void> _scan() async {
    final url = await Navigator.of(context).push<({String host, int port, String secret})>(
      MaterialPageRoute(fullscreenDialog: true, builder: (_) => const _ScanPage()),
    );
    if (url == null || !mounted) return;
    await _pair(_tvFor(url.host, url.port), secret: url.secret);
  }

  void _submit() {
    if (_host.text.trim().isEmpty || _code.text.length != 6 || _busy) return;
    final h = parseHostInput(_host.text);
    if (h == null) {
      setState(() => _error = t('badAddress'));
      return;
    }
    _pair(_tvFor(h.host, h.port), code: _code.text);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tvs = widget.tvs.all;
    return Scaffold(
      appBar: AppBar(title: Text(t('pairTitle'))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: Text(t('scanQr')),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(64),
                textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              ),
            ),
            const SizedBox(height: 28),
            Text(t('typeCode'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
            const SizedBox(height: 14),
            if (widget.host == null && tvs.isNotEmpty) ...[
              Text(t('chooseTv'), style: TextStyle(color: cs.onSurface.withAlpha(180))),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final tv in tvs)
                    ChoiceChip(
                      label: Text(tv.label),
                      selected: _host.text == tv.host,
                      onSelected: (_) => setState(() => _host.text = tv.host),
                    ),
                ],
              ),
              const SizedBox(height: 14),
            ],
            TextField(
              controller: _host,
              keyboardType: TextInputType.url,
              decoration: _field(t('tvAddress')),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 26, letterSpacing: 8, fontWeight: FontWeight.w700),
              decoration: _field(t('codeHint')).copyWith(counterText: ''),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(_error!, style: const TextStyle(color: Color(0xFFFF8A80))),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || _host.text.trim().isEmpty || _code.text.length != 6
                  ? null
                  : _submit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(56),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: _busy
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(strokeWidth: 2.5),
                    )
                  : Text(t('pairNow')),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _field(String hint) => InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: const Color(0x14FFFFFF),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(18),
      borderSide: const BorderSide(color: Color(0x66FFFFFF)),
    ),
  );
}

class _ScanPage extends StatefulWidget {
  const _ScanPage();

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  bool _done = false;

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    for (final b in capture.barcodes) {
      final url = b.rawValue == null ? null : parsePairUrl(b.rawValue!);
      if (url != null) {
        _done = true;
        Navigator.of(context).pop(url);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(
          onDetect: _onDetect,
          errorBuilder: (_, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Text(t('cameraDenied'), textAlign: TextAlign.center),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.topRight,
            child: IconButton(
              tooltip: t('close'),
              iconSize: 32,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ),
        SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Container(
              margin: const EdgeInsets.all(24),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              decoration: BoxDecoration(
                color: const Color(0xB3000000),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Text(t('scanHint'), textAlign: TextAlign.center),
            ),
          ),
        ),
      ],
    ),
  );
}
