import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/justwatch.dart';
import '../data/stremio.dart';
import '../data/tmdb.dart';
import '../data/weather.dart';
import '../data/youtube.dart';
import '../data/youtube_tv.dart';
import '../host.dart';
import '../i18n.dart';
import '../net.dart';
import '../providers.dart';
import '../settings.dart';
import '../sources.dart';
import 'settings_kit.dart';
import 'tile_editor.dart';
import 'tile_icons.dart';

/// What a call shows while it runs.
const _waiting = '…';

/// [key] with all but its last four characters hidden; a key that short is
/// hidden whole.
String maskKey(String key) => key.length <= 4
    ? '•' * key.length
    : '•' * (key.length - 4) + key.substring(key.length - 4);

/// Up, Down and Right leave a text field as they leave a button: on a TV the
/// keyboard edits the text, not the arrows. Left is the pane's, back to its
/// entry.
const _arrows = <ShortcutActivator, Intent>{
  SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(
    TraversalDirection.up,
    ignoreTextFields: false,
  ),
  SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(
    TraversalDirection.down,
    ignoreTextFields: false,
  ),
  SingleActivator(LogicalKeyboardKey.arrowRight): DirectionalFocusIntent(
    TraversalDirection.right,
    ignoreTextFields: false,
  ),
};

/// OK, held or not, presses once.
const _okKey = SingleActivator(
  LogicalKeyboardKey.select,
  includeRepeats: false,
);

/// A text field for the D-pad, [width] wide; [field] builds it read-only or
/// not, and with `enableInteractiveSelection: false` (no touch handles on a
/// TV). Focus alone leaves it read-only, so passing through opens no keyboard.
/// OK makes it editable, which opens the keyboard, and opens it again if it was
/// closed; leaving the field, or Back closing the keyboard, makes it read-only
/// again. The arrows leave it either way (see [_arrows]).
class TvField extends StatefulWidget {
  final TextField Function(bool readOnly) field;
  final double width;
  const TvField(this.field, {super.key, this.width = 320});

  @override
  State<TvField> createState() => _TvFieldState();
}

class _TvFieldState extends State<TvField> with WidgetsBindingObserver {
  var _typing = false;
  var _keyboardUp = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Flutter does not see the Back that closes the keyboard: it shows only as
  /// the window's bottom inset going. (The view's, since the Scaffold takes it
  /// out of MediaQuery.)
  @override
  void didChangeMetrics() {
    final up = View.of(context).viewInsets.bottom > 0;
    if (_keyboardUp && !up && _typing) setState(() => _typing = false);
    _keyboardUp = up;
  }

  /// Once editable, the field opens the keyboard after the frame; when it
  /// already is, the keyboard is asked for again.
  void _ok() {
    setState(() => _typing = true);
    primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>()
        ?.requestKeyboard();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    child: Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (!focused) setState(() => _typing = false);
      },
      child: Shortcuts(
        shortcuts: {..._arrows, _okKey: VoidCallbackIntent(_ok)},
        child: widget.field(!_typing),
      ),
    ),
  );
}

const _radius = BorderRadius.all(Radius.circular(tileRadius));

/// Read from the couch like a button: dim at rest, a white ring with focus.
InputDecoration fieldDecoration(String hint) => InputDecoration(
  hintText: hint,
  counterText: '',
  isDense: true,
  filled: true,
  fillColor: const Color(0x1FFFFFFF),
  enabledBorder: const OutlineInputBorder(
    borderSide: BorderSide.none,
    borderRadius: _radius,
  ),
  focusedBorder: const OutlineInputBorder(
    borderSide: BorderSide(color: Colors.white, width: 2),
    borderRadius: _radius,
  ),
);

/// An installed app's icon, fetched when its row is built; [Icons.apps]
/// until then or if it fails. Dropped from [imageCache] with the row.
class _AppIcon extends StatefulWidget {
  final String package;
  const _AppIcon(this.package);

  @override
  State<_AppIcon> createState() => _AppIconState();
}

class _AppIconState extends State<_AppIcon> {
  Uint8List? _png;

  @override
  void initState() {
    super.initState();
    Host.appIcon(widget.package).then((png) {
      if (mounted) setState(() => _png = png);
    }, onError: (_) {});
  }

  @override
  void dispose() {
    if (_png case final png?) MemoryImage(png).evict();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => switch (_png) {
    final png? => ClipRRect(
      borderRadius: const BorderRadius.all(Radius.circular(5)),
      child: Image.memory(png, cacheWidth: 48, fit: BoxFit.cover),
    ),
    null => const Icon(Icons.apps),
  };
}

/// A text field drawn as a row: dim at rest, a white ring with focus.
InputDecoration _rowField(String hint) => fieldDecoration(hint).copyWith(
  fillColor: const Color(0x14FFFFFF),
  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
  enabledBorder: const OutlineInputBorder(
    borderSide: BorderSide.none,
    borderRadius: BorderRadius.all(Radius.circular(8)),
  ),
  focusedBorder: const OutlineInputBorder(
    borderSide: BorderSide(color: Colors.white, width: 2),
    borderRadius: BorderRadius.all(Radius.circular(8)),
  ),
);

// In their own language, so anyone can find theirs.
const kLanguageNames = {'en': 'English', 'pt': 'Português'};

/// The languages, the current one ticked; OK switches to one.
class LanguagePane extends StatelessWidget {
  final Settings settings;
  final Sources sources;
  const LanguagePane(this.settings, this.sources, {super.key});

  /// TMDB answers in the language, and Stremio's "S2 · E5" is written when the
  /// row is fetched, so both are asked again.
  Future<void> _set(String language) async {
    if (language == settings.language) return;
    settings.language = language;
    I18n.language = language;
    await settings.save();
    sources.tmdb.refresh(force: true).ignore();
    sources.stremio.refresh(force: true).ignore();
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    children: [
      for (final MapEntry(key: code, value: name) in kLanguageNames.entries)
        SettingsRow(
          title: name,
          valueIcon: code == settings.language ? Icons.check : null,
          onPressed: () => _set(code),
        ),
    ],
  );
}

/// The offered apps (`offeredApps`), each a row whose OK takes it out of the
/// Apps grid and the app picker or puts it back, with Open beside. Every
/// change saves.
class AppsPane extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  const AppsPane(this.settings, this.apps, {super.key});

  @override
  State<AppsPane> createState() => _AppsPaneState();
}

class _AppsPaneState extends State<AppsPane> {
  Future<void> _toggle(String package) async {
    final hidden = widget.settings.hiddenApps;
    if (!hidden.remove(package)) hidden.add(package);
    await widget.settings.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final hidden = widget.settings.hiddenApps;
    // ponytail: every row (and its icon) built at once; a ListView.builder if
    // a TV ever has hundreds of apps.
    return SettingsGroup(
      footer: t('appsHelp'),
      children: [
        for (final app in offeredApps(widget.apps).values)
          SettingsRow(
            key: ValueKey(app.package),
            leading: _AppIcon(app.package),
            title: app.label,
            value: t(hidden.contains(app.package) ? 'hidden' : 'shown'),
            onPressed: () => _toggle(app.package),
            extras: [
              RoundIconButton(
                Icons.open_in_new,
                label: t('openApp'),
                onPressed: () => Host.launch(app.package).ignore(),
              ),
            ],
          ),
      ],
    );
  }
}

/// Which app opens movies, series and videos. Movies and series: an
/// installed app that opens Stremio's links, or "My streaming apps" (each
/// title in the app of a service that has it, mapped in [ServicesPane]).
/// Videos: an app that opens YouTube's links, or any other installed one.
/// [titles] and [videos] say which of the two it shows.
class ProvidersPane extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  final Post post;
  final bool titles;
  final bool videos;
  const ProvidersPane(
    this.settings,
    this.apps, {
    this.post = postJson,
    this.titles = true,
    this.videos = true,
    super.key,
  });

  @override
  State<ProvidersPane> createState() => _ProvidersPaneState();
}

const _otherApp = 'ilonatv:other';

class _ProvidersPaneState extends State<ProvidersPane> {
  // The apps that open a Stremio title and a YouTube video; null until the
  // platform answers.
  List<String>? _stremioApps;
  List<String>? _youtubeApps;

  @override
  void initState() {
    super.initState();
    _probe();
  }

  Future<void> _probe() async {
    Future<List<String>> appsFor(String uri) =>
        Host.appsFor(uri).catchError((_) => <String>[]);
    final (stremio, youtube) = await (
      appsFor(kStremioProbe),
      appsFor(kYoutubeProbe),
    ).wait;
    if (!mounted) return;
    setState(() {
      _stremioApps = stremio;
      _youtubeApps = youtube;
    });
  }

  /// The installed apps among [candidates], by label as the apps are sorted.
  Map<String, InstalledApp> _installed(List<String> candidates) => {
    for (final e in widget.apps.entries)
      if (candidates.contains(e.key)) e.key: e.value,
  };

  Future<void> _choose(
    Map<String, InstalledApp> choices,
    List<(String, String)> first,
    String current,
    void Function(String) write,
  ) async {
    var package = await pickAppDialog(
      context,
      choices,
      first: first,
      focus: current,
    );
    if (package == _otherApp && mounted) {
      package = await pickAppDialog(
        context,
        offeredApps(widget.apps),
        focus: current,
      );
    }
    if (package == null) return;
    write(package);
    await widget.settings.save();
    if (mounted) setState(() {});
  }

  Future<void> _toggleAutoPlay() async {
    widget.settings.stremioAutoPlay = !widget.settings.stremioAutoPlay;
    await widget.settings.save();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final stremio = _stremioApps;
    final youtube = _youtubeApps;
    String label(String package, String empty) => package.isEmpty
        ? empty
        : widget.apps[package]?.label ?? t('notInstalled');
    final titles = widget.titles;
    final streaming =
        titles && (s.movieProvider.isEmpty || s.seriesProvider.isEmpty);
    return settingsGroups([
      SettingsGroup(
        children: [
          for (final (key, package, write)
              in <(String, String, void Function(String))>[
                if (titles)
                  (
                    'moviesProvider',
                    s.movieProvider,
                    (p) => s.movieProvider = p,
                  ),
                if (titles)
                  (
                    'seriesProvider',
                    s.seriesProvider,
                    (p) => s.seriesProvider = p,
                  ),
              ])
            // Until the platform answers, OK is ignored.
            SettingsRow(
              title: t(key),
              value: label(package, t('myStreamingApps')),
              chevron: true,
              onPressed: () {
                if (stremio == null) return;
                _choose(
                  _installed(stremio),
                  [('', t('myStreamingApps'))],
                  package,
                  write,
                );
              },
            ),
          if (widget.videos)
            SettingsRow(
              title: t('youtubeProvider'),
              value: label(s.youtubeProvider, t('anyApp')),
              chevron: true,
              onPressed: () {
                if (youtube == null) return;
                _choose(
                  _installed(youtube),
                  [(_otherApp, t('otherApp'))],
                  s.youtubeProvider,
                  (p) => s.youtubeProvider = p,
                );
              },
            ),
        ],
      ),
      if (streaming)
        SettingsGroup(
          footer: t('streamingServicesHelp'),
          children: [
            SettingsRow(
              title: t('streamingServices'),
              value:
                  '${s.serviceApps.values.where((p) => p.isNotEmpty).length}',
              chevron: true,
              onPressed: () => pushSettingsPage(
                context,
                title: () => t('streamingServices'),
                icon: Icons.open_in_new,
                listen: s,
                build: () => ServicesPane(s, widget.apps, post: widget.post),
              ),
            ),
          ],
        ),
      // The first-stream tap knows only this build's views.
      if (titles &&
          (s.movieProvider == kStremioPackage ||
              s.seriesProvider == kStremioPackage))
        SettingsGroup(
          footer: t('stremioAutoPlayHelp'),
          children: [
            SettingsRow(
              title: t('stremioAutoPlay'),
              value: t(s.stremioAutoPlay ? 'on' : 'off'),
              onPressed: _toggleAutoPlay,
            ),
          ],
        ),
    ]);
  }
}

/// The subscription services of [Settings.country] as JustWatch lists them,
/// in its order there, each with the app it opens in: the one chosen, else a
/// [suggestedApp] to confirm. OK picks from every installed app, or None.
/// Every change saves.
class ServicesPane extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  final Post post;
  const ServicesPane(
    this.settings,
    this.apps, {
    this.post = postJson,
    super.key,
  });

  @override
  State<ServicesPane> createState() => _ServicesPaneState();
}

class _ServicesPaneState extends State<ServicesPane> {
  List<WatchProvider>? _services;
  var _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final s = widget.settings;
    if (s.tmdbKey.isEmpty) return;
    try {
      final all = await JustWatchClient(widget.post).services(s.country);
      if (mounted) setState(() => _services = all);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _load();
  }

  Future<void> _pick(WatchProvider service, String? suggested) async {
    final map = widget.settings.serviceApps;
    final package = await pickAppDialog(
      context,
      offeredApps(widget.apps),
      first: [('', t('none'))],
      focus: map['${service.id}'] ?? suggested,
    );
    if (package == null) return;
    // '' is a None that was picked, so no suggestion shows again.
    map['${service.id}'] = package;
    await widget.settings.save();
  }

  @override
  Widget build(BuildContext context) {
    focusFirstRow(context);
    final s = widget.settings;
    final shown = _services ?? const [];
    return SettingsGroup(
      footer: s.tmdbKey.isEmpty
          ? t('servicesNeedKey')
          : _failed
          ? t('networkError')
          : _services == null
          ? _waiting
          : t('streamingServicesHelp'),
      children: [
        if (_failed)
          SettingsRow(
            leading: const Icon(Icons.refresh),
            title: t('checkAgain'),
            onPressed: _retry,
          ),
        for (final w in shown)
          Builder(
            builder: (context) {
              final chosen = s.serviceApps['${w.id}'];
              final suggested = chosen == null
                  ? suggestedApp(w.name, offeredApps(widget.apps))
                  : null;
              return SettingsRow(
                key: ValueKey(w.id),
                title: w.name,
                value: chosen == null
                    ? suggested == null
                          ? t('none')
                          : t(
                              'suggestedApp',
                            ).replaceAll('{app}', widget.apps[suggested]!.label)
                    : chosen.isEmpty
                    ? t('none')
                    : widget.apps[chosen]?.label ?? t('notInstalled'),
                chevron: true,
                onPressed: () => _pick(w, suggested),
              );
            },
          ),
      ],
    );
  }
}

/// The Stremio account: log in from a phone, with a code and a QR that the
/// phone approves, or log out. The body of a card of [KeysPane].
class StremioPane extends StatefulWidget {
  final Settings settings;
  final StremioSource source;
  const StremioPane(this.settings, this.source, {super.key});

  @override
  State<StremioPane> createState() => _StremioPaneState();
}

class _StremioPaneState extends State<StremioPane> {
  var _running = false;
  String? _message;

  /// Set when a call starts: the first control of the layout that follows takes
  /// focus. Not before, or it would take it from the entries. The layout can
  /// change while the call still runs (the account is kept, or dropped, before
  /// the row is fetched or the cache deleted), and with no call at all, when
  /// the phone approves or the wait ends.
  var _refocus = false;

  /// The QR image of the code on screen, asked for once per code and not at
  /// every build. [Future.sync], so a URL that does not parse is a failed
  /// image, as any other, and not an error in the build.
  String? _qrUrl;
  Future<Uint8List>? _qr;

  @override
  void dispose() {
    // Not now: the home listens to the source, and the framework refuses a
    // setState while the tree is being taken apart.
    Future.microtask(widget.source.cancelLink);
    super.dispose();
  }

  /// Runs a call to log in or out. The buttons stay enabled and ignore presses
  /// meanwhile: a disabled button cannot keep focus. A call that Stremio
  /// refuses shows its message; any other failure, a network error.
  Future<void> _run(Future<void> Function() call) async {
    if (_running) return;
    setState(() {
      _running = true;
      _message = _waiting;
      _refocus = true;
    });
    String? message;
    try {
      await call();
    } on StremioError catch (e) {
      message = e.message;
    } catch (_) {
      message = t('networkError');
    }
    if (!mounted) return;
    setState(() {
      _running = false;
      _message = message;
    });
  }

  Future<Uint8List> _qrFor(String url) {
    if (url != _qrUrl) {
      _qrUrl = url;
      _qr = Future.sync(() => getBytes(Uri.parse(url)));
    }
    return _qr!;
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final source = widget.source;
    return ListenableBuilder(
      // The account is in the settings, and the wait for the phone in the
      // source.
      listenable: Listenable.merge([s, source]),
      builder: (context, _) {
        // Only while focus is still in the pane: a call or a wait that ends
        // after the user went back to the entries leaves focus there.
        final refocus =
            _refocus &&
            FocusScope.of(context, createDependency: false).hasFocus;
        final code = source.linkCode;
        final message = _message;
        return SettingsGroup(
          header: s.stremioAuthKey.isEmpty
              ? t('notLoggedIn')
              : '${t('loggedInAs')} ${s.stremioEmail}',
          footer: s.stremioAuthKey.isEmpty && code == null ? message : null,
          children: [
            if (s.stremioAuthKey.isNotEmpty) ...[
              SettingsRow(
                title: t('logout'),
                autofocus: refocus,
                onPressed: () => _run(source.logout),
              ),
            ] else if (code != null) ...[
              // Nothing while it loads or if it fails: the code is below.
              FutureBuilder(
                future: _qrFor(code.qrcodeUrl),
                builder: (context, snapshot) => switch (snapshot.data) {
                  final bytes? => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: ClipRRect(
                        borderRadius: const BorderRadius.all(
                          Radius.circular(8),
                        ),
                        child: Image.memory(
                          bytes,
                          width: 180,
                          height: 180,
                          // Decoded at the screen's pixels, and not smoothed:
                          // a QR is read by its edges.
                          cacheWidth:
                              (180 * MediaQuery.devicePixelRatioOf(context))
                                  .round(),
                          filterQuality: FilterQuality.none,
                        ),
                      ),
                    ),
                  ),
                  null => const SizedBox.shrink(),
                },
              ),
              _Code(
                code.code,
                '${t('linkOpen')} link.stremio.com/${code.code} '
                '${t('linkApprove')}',
              ),
              SettingsRow(
                title: t('cancel'),
                autofocus: refocus,
                onPressed: source.cancelLink,
              ),
            ] else ...[
              if (source.linkExpired)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(t('linkExpired'), style: settingsNote),
                ),
              SettingsRow(
                title: t('loginWithPhone'),
                autofocus: refocus,
                onPressed: () => _run(source.startLink),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// A sign-in code to type on a phone, big, with where to type it and that
/// the TV waits.
class _Code extends StatelessWidget {
  final String code;
  final String where;
  const _Code(this.code, this.where);

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: 4,
      children: [
        Text(
          code,
          style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w700),
        ),
        Text(where, style: settingsNote),
        Text(t('waiting'), style: settingsNote),
      ],
    ),
  );
}

/// The accounts and keys, a row per service whose OK opens its screen:
/// YouTube; Stremio, when a provider of titles is one of [stremioApps], the
/// apps that open Stremio's links; and the TMDB key.
class AccountsPane extends StatelessWidget {
  final Settings settings;
  final Sources sources;
  final List<String> stremioApps;
  const AccountsPane(
    this.settings,
    this.sources, {
    required this.stremioApps,
    super.key,
  });

  void _open(
    BuildContext context,
    String Function() title,
    IconData icon,
    Widget Function() build,
  ) => pushSettingsPage(
    context,
    title: title,
    icon: icon,
    listen: settings,
    build: build,
  );

  @override
  Widget build(BuildContext context) {
    final s = settings;
    return SettingsGroup(
      children: [
        SettingsRow(
          title: t('youtube'),
          value: '${s.youtubeAccounts.length}',
          chevron: true,
          onPressed: () => _open(
            context,
            () => t('youtube'),
            Icons.smart_display_outlined,
            () => YoutubePane(s, sources.youtube, sources.youtubeSignIn),
          ),
        ),
        // A logged-in account always shows, so Log out stays reachable.
        if (s.stremioAuthKey.isNotEmpty ||
            showStremioAccount(
              movieProvider: s.movieProvider,
              seriesProvider: s.seriesProvider,
              stremioApps: stremioApps,
            ))
          SettingsRow(
            title: 'Stremio',
            value: s.stremioAuthKey.isEmpty ? t('notLoggedIn') : s.stremioEmail,
            chevron: true,
            onPressed: () => _open(
              context,
              () => 'Stremio',
              Icons.movie_filter_outlined,
              () => StremioPane(s, sources.stremio),
            ),
          ),
        SettingsRow(
          title: 'TMDB',
          value: t(s.tmdbKey.isEmpty ? 'noKey' : 'keySaved'),
          chevron: true,
          onPressed: () => _open(
            context,
            () => 'TMDB',
            Icons.local_movies_outlined,
            () => TmdbPane(s, sources.tmdb),
          ),
        ),
        // The voice assistant's brain; only useful where the mic button opens Ilona TV.
        if (s.alexaBounce)
          SettingsRow(
            title: 'Gemini',
            value: t(s.geminiKey.isEmpty ? 'noKey' : 'keySaved'),
            chevron: true,
            onPressed: () => _open(
              context,
              () => 'Gemini',
              Icons.mic_none_outlined,
              () => GeminiPane(s),
            ),
          ),
      ],
    );
  }
}

/// The Gemini key for the voice assistant, typed on the TV, shown masked, with
/// a test (one models listing). The native assistant reads it from prefs.
class GeminiPane extends StatelessWidget {
  final Settings settings;
  const GeminiPane(this.settings, {super.key});

  @override
  Widget build(BuildContext context) => _KeyRow(
    label: t('geminiKey'),
    value: settings.geminiKey,
    test: (key) => getJson(
      Uri.https('generativelanguage.googleapis.com', '/v1beta/models', {
        'pageSize': '1',
      }),
      headers: {'x-goog-api-key': key},
    ),
    save: (key) async {
      settings.geminiKey = key;
      await settings.save();
    },
  );
}

/// The TMDB key, typed on the TV, shown masked, with a test. A key saved
/// empty takes its rows away, cache and all: without a key a row does not
/// show. Any other key is asked with at once.
class TmdbPane extends StatelessWidget {
  final Settings settings;
  final TmdbSource tmdb;
  const TmdbPane(this.settings, this.tmdb, {super.key});

  @override
  Widget build(BuildContext context) => _KeyRow(
    label: t('tmdbKey'),
    value: settings.tmdbKey,
    test: tmdb.testKey,
    save: (key) async {
      settings.tmdbKey = key;
      await settings.save();
      (key.isEmpty ? tmdb.clear() : tmdb.refresh(force: true)).ignore();
    },
  );
}

/// A profile's picture, small; blank without one or while it loads.
Widget _avatar(String? url) => ClipOval(
  child: SizedBox.square(
    dimension: 24,
    child: ColoredBox(
      color: const Color(0x1FFFFFFF),
      child: url == null
          ? null
          : Image.network(
              url,
              cacheWidth: 48,
              fit: BoxFit.cover,
              errorBuilder: (_, _, _) => const SizedBox(),
            ),
    ),
  ),
);

/// The YouTube accounts: each a row whose OK turns its home row on or off,
/// or signs in again once YouTube signed it out, with Remove beside. Below, adding a login from a
/// phone: a code to type at google.com/device, then the profiles of that login
/// to pick from. Leaving the pane ends the sign-in.
class YoutubePane extends StatefulWidget {
  final Settings settings;
  final YoutubeSource source;
  final YoutubeSignIn signIn;
  const YoutubePane(this.settings, this.source, this.signIn, {super.key});

  @override
  State<YoutubePane> createState() => _YoutubePaneState();
}

class _YoutubePaneState extends State<YoutubePane> {
  final _addNode = FocusNode();
  final _cancelNode = FocusNode();
  final _keepNode = FocusNode();

  /// The [YoutubeSignIn.choices] left out, by [YtAccount.key]: all are in
  /// at first.
  final _unticked = <String>{};

  /// Where focus goes in the sign-in's current step.
  late FocusNode _step = _target;

  FocusNode get _target => widget.signIn.choices != null
      ? _keepNode
      : widget.signIn.code != null
      ? _cancelNode
      : _addNode;

  @override
  void initState() {
    super.initState();
    widget.signIn.addListener(_follow);
  }

  @override
  void dispose() {
    widget.signIn.removeListener(_follow);
    widget.signIn.cancel();
    // Back in the pane, an old failure is not news.
    widget.signIn.error = null;
    _addNode.dispose();
    _cancelNode.dispose();
    _keepNode.dispose();
    super.dispose();
  }

  /// A new step takes focus: the code to Cancel, the profiles to Add, the end
  /// to Add account. Only while focus is still in the pane.
  void _follow() {
    final next = _target;
    if (!mounted || next == _step) return;
    _step = next;
    _unticked.clear();
    if (!FocusScope.of(context, createDependency: false).hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (next.context != null) next.requestFocus();
    });
  }

  Future<void> _keep(List<YtAccount> accounts) {
    widget.settings.youtubeAccounts = accounts;
    return widget.settings.save();
  }

  Future<void> _toggle(YtAccount a) => _keep([
    for (final b in widget.settings.youtubeAccounts)
      b.key == a.key ? b.copyWith(enabled: !b.enabled) : b,
  ]);

  /// Focus, whose button goes, lands where the sign-in's step puts it.
  Future<void> _remove(YtAccount a) async {
    await _keep([
      for (final b in widget.settings.youtubeAccounts)
        if (b.key != a.key) b,
    ]);
    final target = _target;
    if (mounted && target.context != null) target.requestFocus();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    // Revoked accounts are known to the source.
    listenable: Listenable.merge([
      widget.settings,
      widget.source,
      widget.signIn,
    ]),
    builder: (context, _) {
      final signIn = widget.signIn;
      final accounts = widget.settings.youtubeAccounts;
      final on = accounts
          .where((a) => a.enabled && !widget.source.isRevoked(a))
          .length;
      final code = signIn.code;
      final choices = signIn.choices;
      final error = switch (signIn.error) {
        null => null,
        'expired' => 'ytCodeExpired',
        'network' => 'networkError',
        _ => 'ytDenied',
      };
      // With no account, the status heads the sign-in's rows.
      final status = accounts.isEmpty ? t('noAccount') : null;
      return settingsGroups([
        if (accounts.isNotEmpty)
          SettingsGroup(
            header: '$on ${t(on == 1 ? 'profileOn' : 'profilesOn')}',
            children: [
              for (final a in accounts)
                SettingsRow(
                  key: ValueKey(a.key),
                  leading: _avatar(a.avatarUrl),
                  title: a.name,
                  value: widget.source.isRevoked(a)
                      ? t('signInAgain')
                      : t(a.enabled ? 'on' : 'off'),
                  onPressed: widget.source.isRevoked(a)
                      ? signIn.start
                      : () => _toggle(a),
                  extras: [
                    RoundIconButton(
                      Icons.delete_outline,
                      label: t('remove'),
                      onPressed: () => _remove(a),
                    ),
                  ],
                ),
            ],
          ),
        if (choices != null)
          SettingsGroup(
            header: t('chooseProfiles'),
            children: [
              for (final c in choices)
                SettingsRow(
                  leading: _avatar(c.avatarUrl),
                  title: c.name,
                  valueIcon: _unticked.contains(c.key) ? null : Icons.check,
                  onPressed: () => setState(() {
                    if (!_unticked.remove(c.key)) _unticked.add(c.key);
                  }),
                ),
              SettingsRow(
                title: t('add'),
                focusNode: _keepNode,
                onPressed: () => signIn.addChosen([
                  for (final c in choices)
                    if (!_unticked.contains(c.key)) c,
                ]),
              ),
              SettingsRow(title: t('cancel'), onPressed: signIn.cancel),
            ],
          )
        else if (code != null)
          SettingsGroup(
            header: status,
            children: [
              _Code(
                code.userCode,
                '${t('linkOpen')} '
                '${code.verificationUrl.replaceFirst(RegExp(r'^\w+://(www\.)?'), '')} '
                '${t('ytEnterCode')}',
              ),
              // Also while the profiles are asked after the phone said yes,
              // which has no end of its own.
              SettingsRow(
                title: t('cancel'),
                focusNode: _cancelNode,
                onPressed: signIn.cancel,
              ),
            ],
          )
        else
          SettingsGroup(
            header: status,
            footer: error == null ? null : t(error),
            children: [
              SettingsRow(
                title: t('addAccount'),
                focusNode: _addNode,
                onPressed: signIn.start,
              ),
            ],
          ),
      ]);
    },
  );
}

/// The key of [TmdbPane]: masked, or in a field while it is edited.
class _KeyRow extends StatefulWidget {
  final String label;
  final String value;

  /// One call to the service with the key; it throws as the client does.
  final Future<void> Function(String key) test;
  final Future<void> Function(String key) save;

  const _KeyRow({
    required this.label,
    required this.value,
    required this.test,
    required this.save,
  });

  @override
  State<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends State<_KeyRow> {
  final _field = TextEditingController();
  final _fieldNode = FocusNode();
  final _editNode = FocusNode();
  final _saveNode = FocusNode();
  var _editing = false;
  var _testing = false;
  String? _result;

  /// A key saved elsewhere (the phone) while one is typed here wins: the
  /// field closes, so what was typed is not saved over it.
  @override
  void didUpdateWidget(_KeyRow old) {
    super.didUpdateWidget(old);
    if (old.value == widget.value || !_editing) return;
    final focused = _fieldNode.hasFocus || _saveNode.hasFocus;
    _editing = false;
    _result = null;
    if (focused) _editNode.requestFocus();
  }

  @override
  void dispose() {
    // A key typed with the remote is not lost to a Continue or Back.
    final typed = _field.text.trim();
    if (_editing && typed.isNotEmpty && typed != widget.value) {
      widget.save(typed);
    }
    _field.dispose();
    _fieldNode.dispose();
    _editNode.dispose();
    _saveNode.dispose();
    super.dispose();
  }

  void _edit() {
    _field.text = widget.value;
    setState(() {
      _editing = true;
      _result = null;
    });
    _fieldNode.requestFocus(); // once the field is built
  }

  /// Tests the key being typed, else the saved one.
  Future<void> _test() async {
    if (_testing) return;
    final key = (_editing ? _field.text : widget.value).trim();
    setState(() {
      _testing = true;
      _result = _waiting;
    });
    String result;
    try {
      await widget.test(key);
      result = 'keyOk';
    } on TmdbError catch (e) {
      result = e == TmdbError.badKey ? 'keyBad' : 'networkError';
    } catch (_) {
      // An answer the client could not read.
      result = 'networkError';
    }
    if (!mounted) return;
    setState(() {
      _testing = false;
      _result = t(result);
    });
  }

  Future<void> _save() async {
    await widget.save(_field.text.trim());
    if (!mounted) return;
    // A verdict on the key before is not one on this one.
    setState(() {
      _editing = false;
      _result = null;
    });
    _editNode.requestFocus(); // once the button is built
  }

  @override
  Widget build(BuildContext context) => SettingsGroup(
    footer: _result,
    children: [
      if (_editing)
        TvField(
          (readOnly) => TextField(
            controller: _field,
            focusNode: _fieldNode,
            readOnly: readOnly,
            enableInteractiveSelection: false,
            autocorrect: false,
            enableSuggestions: false,
            // Typed in plain text: the keyboard must not learn it.
            enableIMEPersonalizedLearning: false,
            onEditingComplete: _saveNode.requestFocus,
            style: const TextStyle(fontSize: 15),
            decoration: _rowField(widget.label),
          ),
          width: double.infinity,
        )
      else
        // OK edits it.
        SettingsRow(
          key: const ValueKey('edit'),
          focusNode: _editNode,
          title: widget.label,
          value: widget.value.isEmpty ? t('notSet') : maskKey(widget.value),
          chevron: true,
          onPressed: _edit,
        ),
      if (_editing)
        SettingsRow(
          key: const ValueKey('save'),
          focusNode: _saveNode,
          title: t('save'),
          onPressed: _save,
        ),
      SettingsRow(
        key: const ValueKey('test'),
        title: t('testKey'),
        onPressed: _test,
      ),
    ],
  );
}

/// The city of the weather line, found by name.
class WeatherPane extends StatefulWidget {
  final Settings settings;
  final WeatherSource source;
  const WeatherPane(this.settings, this.source, {super.key});

  @override
  State<WeatherPane> createState() => _WeatherPaneState();
}

class _WeatherPaneState extends State<WeatherPane> {
  final _query = TextEditingController();
  final _searchNode = FocusNode();
  final _firstPlace = FocusNode();
  final _fieldNode = FocusNode();
  final _changeNode = FocusNode();
  var _open = false;
  var _searching = false;
  var _places = <Place>[];

  /// The last search found nothing (or the network failed: the source cannot
  /// tell).
  var _noResults = false;

  late String _city;

  @override
  void initState() {
    super.initState();
    _city = widget.settings.weatherCity;
  }

  /// A city picked elsewhere (the phone) ends a search open here.
  @override
  void didUpdateWidget(WeatherPane old) {
    super.didUpdateWidget(old);
    if (widget.settings.weatherCity == _city) return;
    _city = widget.settings.weatherCity;
    if (!_open) return;
    final focused =
        primaryFocus != _changeNode &&
        primaryFocus?.context?.findAncestorStateOfType<_WeatherPaneState>() ==
            this;
    _open = false;
    _places = [];
    _noResults = false;
    if (focused) _changeNode.requestFocus();
  }

  @override
  void dispose() {
    _query.dispose();
    _searchNode.dispose();
    _firstPlace.dispose();
    _fieldNode.dispose();
    _changeNode.dispose();
    super.dispose();
  }

  /// The field shows, with focus: OK on it opens the keyboard.
  void _openSearch() {
    setState(() => _open = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fieldNode.requestFocus();
    });
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (_searching || query.isEmpty) return;
    // Off the field, so the keyboard closes and focus shows while it runs.
    _searchNode.requestFocus();
    setState(() {
      _searching = true;
      _noResults = false;
    });
    final places = await widget.source.search(query); // never throws
    if (!mounted) return;
    setState(() {
      _searching = false;
      _places = places.take(5).toList();
      _noResults = places.isEmpty;
    });
    if (places.isNotEmpty) _firstPlace.requestFocus();
  }

  Future<void> _pick(Place place) async {
    await widget.settings.applyPlace(place);
    widget.source.refresh(force: true).ignore();
    if (!mounted) return;
    setState(() {
      _open = false;
      _places = [];
    });
    _changeNode.requestFocus();
  }

  Future<void> _toggleUnit() async {
    widget.settings.fahrenheit = !widget.settings.fahrenheit;
    await widget.settings.save();
    widget.source.refresh(force: true).ignore();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => settingsGroups([
    SettingsGroup(
      children: [
        SettingsRow(
          title: t('city'),
          value: widget.settings.weatherCity.isEmpty
              ? t('notSet')
              : widget.settings.weatherCity,
          focusNode: _changeNode,
          onPressed: _openSearch,
        ),
        SettingsRow(
          title: t('temperatureUnit'),
          value: widget.settings.fahrenheit ? '°F' : '°C',
          onPressed: _toggleUnit,
        ),
      ],
    ),
    if (_open)
      SettingsGroup(
        footer: _searching
            ? _waiting
            : _noResults
            ? t('noResults')
            : null,
        children: [
          TvField(
            (readOnly) => TextField(
              controller: _query,
              focusNode: _fieldNode,
              readOnly: readOnly,
              enableInteractiveSelection: false,
              textInputAction: TextInputAction.search,
              onEditingComplete: _search,
              style: const TextStyle(fontSize: 15),
              decoration: _rowField(t('city')),
            ),
            width: double.infinity,
          ),
          SettingsRow(
            title: t('search'),
            focusNode: _searchNode,
            onPressed: _search,
          ),
          for (final (i, place) in _places.indexed)
            SettingsRow(
              focusNode: i == 0 ? _firstPlace : null,
              leading: const Icon(Icons.place_outlined),
              title: place.name,
              value: [
                place.region,
                place.country,
              ].where((part) => part.isNotEmpty).join(', '),
              onPressed: () => _pick(place),
            ),
        ],
      ),
  ]);
}

/// The app row first, whose OK opens [TileEditor] on a page of its own (Back
/// comes back here); then each content row of the home in its order, whose
/// OK turns it on or off, with up / down beside. Every change saves, which redraws the home.
class RowsPane extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  const RowsPane(this.settings, this.apps, {super.key});

  @override
  State<RowsPane> createState() => _RowsPaneState();
}

class _RowsPaneState extends State<RowsPane> {
  // By (row key, action), so focus follows a moved row.
  final _nodes = <(String, String), FocusNode>{};

  List<HomeRow> get _rows => widget.settings.homeRows;

  @override
  void dispose() {
    for (final node in _nodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  FocusNode _node(String key, String action) =>
      _nodes.putIfAbsent((key, action), FocusNode.new);

  Future<void> _save() async {
    await widget.settings.save();
    if (mounted) setState(() {});
  }

  void _toggle(int i) {
    final r = _rows[i];
    _rows[i] = (key: r.key, on: !r.on);
    _save();
  }

  /// The button keeps focus as its row moves; past either end nothing moves.
  Future<void> _move(int i, int to, String action) async {
    if (to < 0 || to >= _rows.length) return;
    final key = _rows[i].key;
    _rows.insert(to, _rows.removeAt(i));
    await _save();
    // As TileEditor._saveAndFocus.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final node = _node(key, action)..requestFocus();
      final context = node.context;
      if (context == null) return;
      FocusTraversalGroup.of(context).invalidateScopeData(node.nearestScope!);
      Scrollable.ensureVisible(context, alignment: 0.5);
    });
  }

  void _openTileEditor() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => _TileEditorPage(widget.settings, widget.apps),
    ),
  );

  Widget _row(int i) {
    final r = _rows[i];
    Widget move(String action, IconData icon, int to) => RoundIconButton(
      icon,
      label: t(action),
      focusNode: _node(r.key, action),
      onPressed: () => _move(i, to, action),
    );
    return SettingsRow(
      key: ValueKey(r.key),
      title: t(r.key),
      value: t(r.on ? 'on' : 'off'),
      focusNode: _node(r.key, 'switch'),
      onPressed: () => _toggle(i),
      extras: [
        move('moveUp', Icons.arrow_upward, i - 1),
        move('moveDown', Icons.arrow_downward, i + 1),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => settingsGroups([
    SettingsGroup(
      footer: t('appRowSub'),
      children: [
        SettingsRow(
          title: t('appRow'),
          chevron: true,
          onPressed: _openTileEditor,
        ),
      ],
    ),
    SettingsGroup(
      header: t('contentRows'),
      footer: t('contentRowsHelp'),
      children: [for (var i = 0; i < _rows.length; i++) _row(i)],
    ),
  ]);
}

/// [TileEditor] under its title, on a page of its own: Back closes it.
class _TileEditorPage extends StatefulWidget {
  final Settings settings;
  final Map<String, InstalledApp> apps;
  const _TileEditorPage(this.settings, this.apps);

  @override
  State<_TileEditorPage> createState() => _TileEditorPageState();
}

class _TileEditorPageState extends State<_TileEditorPage> {
  @override
  void initState() {
    super.initState();
    // The editor's first button takes focus, so OK works straight away.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) FocusScope.of(context).nextFocus();
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Scaffold(
      body: Padding(
        // As the Settings screen.
        padding: EdgeInsets.fromLTRB(
          0.04 * size.width,
          0.045 * size.height,
          0.04 * size.width,
          0,
        ),
        child: Column(
          spacing: 0.03 * size.height,
          children: [
            // As a SettingsPage's.
            Text(
              t('appRow'),
              style: const TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: Color(0x99FFFFFF),
              ),
            ),
            Expanded(child: TileEditor(widget.settings, widget.apps)),
          ],
        ),
      ),
    );
  }
}
