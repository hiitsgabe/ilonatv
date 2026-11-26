import 'package:ilonatv_protocol/ilonatv_protocol.dart' show SetupStep;
import 'package:flutter/material.dart';

import '../companion/pairing.dart';
import '../companion/state.dart';
import '../host.dart';
import '../i18n.dart';
import '../launcher_setup.dart';
import '../providers.dart';
import '../settings.dart';
import '../sources.dart';
import 'backdrop.dart';
import 'companion_pane.dart';
import 'glass.dart';
import 'launcher_pane.dart';
import 'settings_kit.dart';
import 'settings_panes.dart';
import 'sports_pane.dart';

/// The dock a first setup leaves: the YouTube app, the apps titles open in
/// (the Stremio app, or the streaming services' apps), then the Apps grid;
/// five at most, as the row holds.
List<AppTile> firstDock(Settings s) {
  final streaming = s.movieProvider.isEmpty || s.seriesProvider.isEmpty;
  final packages = <String>{
    s.youtubeProvider,
    s.movieProvider,
    s.seriesProvider,
    if (streaming) ...s.serviceApps.values,
  }..remove('');
  return [
    for (final p in packages.take(4))
      AppTile(p, p == s.youtubeProvider ? 'youtube' : 'app'),
    const AppTile('ilonatv:apps', 'apps'),
  ];
}

enum _Step {
  welcome,
  location,
  tmdb,
  titles,
  videos,
  stremio,
  sports,
  home,
  done,
}

/// The first run's setup, one step a screen: the step's text and Continue on
/// the left, its Settings pane on the right. Every step can be skipped and
/// Back goes one step back; on the first step it leaves only a re-run, opened
/// from Settings. Done seeds the dock (first run only) and opens the home.
class SetupWizard extends StatefulWidget {
  final Settings settings;
  final Sources sources;
  final Pairing pairing;
  const SetupWizard(
    this.settings,
    this.sources, {
    super.key,
    required this.pairing,
  });

  @override
  State<SetupWizard> createState() => _SetupWizardState();
}

class _SetupWizardState extends State<SetupWizard> {
  final _content = FocusNode(skipTraversal: true, canRequestFocus: false);
  final _continue = FocusNode();
  var _at = _Step.welcome;
  late final _rerun = widget.settings.setupDone;
  Map<String, InstalledApp>? _apps;
  var _stremioApps = const <String>[];
  // The TV's address, once read: until then the welcome step shows no QR.
  String? _ip;
  var _ipKnown = false;

  @override
  void initState() {
    super.initState();
    _publish();
    _loadApps();
    _loadIp();
    _focusStep();
  }

  Future<void> _loadIp() async {
    final ip = await deviceIp();
    if (!mounted) return;
    setState(() {
      _ip = ip;
      _ipKnown = true;
    });
  }

  @override
  void dispose() {
    companionState.setStep(null);
    _content.dispose();
    _continue.dispose();
    super.dispose();
  }

  /// The first run picks the first app that plays YouTube's links.
  Future<void> _loadApps() async {
    Future<List<String>> appsFor(String uri) =>
        Host.appsFor(uri).catchError((_) => <String>[]);
    final (list, stremio, youtube) = await (
      Host.listApps().catchError((_) => <InstalledApp>[]),
      appsFor(kStremioProbe),
      appsFor(kYoutubeProbe),
    ).wait;
    if (!mounted) return;
    final apps = {for (final a in list) a.package: a};
    setState(() {
      _apps = apps;
      _stremioApps = stremio;
    });
    final s = widget.settings;
    final first = apps.keys.where(youtube.contains).firstOrNull;
    if (!s.setupDone && s.youtubeProvider.isEmpty && first != null) {
      s.youtubeProvider = first;
      await s.save();
    }
  }

  List<_Step> get _steps {
    final s = widget.settings;
    final stremio =
        s.stremioAuthKey.isNotEmpty ||
        showStremioAccount(
          movieProvider: s.movieProvider,
          seriesProvider: s.seriesProvider,
          stremioApps: _stremioApps,
        );
    return [
      for (final step in _Step.values)
        // The step being shown stays, so signing out on it keeps the place.
        if (step != _Step.stremio || stremio || _at == step) step,
    ];
  }

  /// Focus goes to the step's first row, or to Continue when it has none.
  void _focusStep() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    (_content.traversalDescendants.firstOrNull ?? _continue).requestFocus();
  });

  void _publish() => companionState.setStep(SetupStep.values.byName(_at.name));

  void _go(int by) {
    final steps = _steps;
    final i = steps.indexOf(_at) + by;
    if (i < 0) return;
    if (i >= steps.length) {
      _finish();
      return;
    }
    setState(() => _at = steps[i]);
    _publish();
    _focusStep();
  }

  Future<void> _finish() async {
    final s = widget.settings;
    if (!s.setupDone) {
      s.tiles = firstDock(s);
      s.setupDone = true;
    }
    final navigator = Navigator.of(context);
    await s.save();
    // A first run's wizard is the first route: the home takes its place.
    navigator.popUntil((r) => r.isFirst);
  }

  (IconData, String, String) get _text => switch (_at) {
    _Step.welcome => (
      Icons.waving_hand_outlined,
      'IlonaTv',
      t('wizWelcomeHelp'),
    ),
    _Step.location => (
      Icons.place_outlined,
      t('wizLocation'),
      t('wizLocationHelp'),
    ),
    _Step.tmdb => (Icons.local_movies_outlined, t('wizTmdb'), t('wizTmdbHelp')),
    _Step.titles => (Icons.movie_outlined, t('wizTitles'), t('wizTitlesHelp')),
    _Step.videos => (
      Icons.smart_display_outlined,
      t('youtube'),
      t('wizVideosHelp'),
    ),
    _Step.stremio => (
      Icons.movie_filter_outlined,
      'Stremio',
      t('wizStremioHelp'),
    ),
    _Step.sports => (
      Icons.sports_soccer_outlined,
      t('sports'),
      t('wizSportsHelp'),
    ),
    _Step.home => (Icons.home_outlined, t('wizHome'), t('wizHomeHelp')),
    _Step.done => (
      Icons.check_circle_outline,
      t('wizDone'),
      t(_rerun ? 'wizDoneAgainHelp' : 'wizDoneHelp'),
    ),
  };

  /// The QR and the code, on the welcome step and, on a first run, the two
  /// steps with typing; a re-run's hint points to Settings instead.
  bool get _phone =>
      _at == _Step.welcome ||
      !_rerun && (_at == _Step.location || _at == _Step.tmdb);

  Widget _pane() {
    final s = widget.settings;
    final sources = widget.sources;
    final apps = _apps ?? const {};
    final usePhone = _phone
        ? null
        : Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(t('useYourPhone'), style: settingsNote),
          );
    // Until the platform answers, OK on an app row would offer nothing.
    if (_apps == null && (_at == _Step.titles || _at == _Step.videos)) {
      return const Text('…', style: settingsNote);
    }
    return switch (_at) {
      _Step.welcome => settingsGroups([
        SettingsGroup(
          header: t('language'),
          children: [LanguagePane(s, sources)],
        ),
      ]),
      _Step.location => settingsGroups([
        WeatherPane(s, sources.weather),
        ?usePhone,
      ]),
      _Step.tmdb => settingsGroups([
        TmdbPane(s, sources.tmdb),
        ?usePhone,
        const TmdbGuide(),
      ]),
      _Step.titles => settingsGroups([
        ProvidersPane(s, apps, videos: false),
        if ((s.movieProvider.isEmpty || s.seriesProvider.isEmpty) &&
            s.tmdbKey.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(t('wizNeedsKey'), style: settingsNote),
          ),
      ]),
      _Step.videos => settingsGroups([
        ProvidersPane(s, apps, titles: false),
        YoutubePane(s, sources.youtube, sources.youtubeSignIn),
      ]),
      _Step.stremio => StremioPane(s, sources.stremio),
      _Step.sports => SportsPane(s),
      _Step.home => LauncherPane(s),
      _Step.done => const Icon(
        Icons.check_circle_outline,
        size: 120,
        color: Color(0x33FFFFFF),
      ),
    };
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.settings,
    builder: (context, _) {
      final steps = _steps;
      final at = steps.indexOf(_at);
      final last = at == steps.length - 1;
      final skippable = at > 0 && !last;
      final (icon, title, help) = _text;
      final size = MediaQuery.sizeOf(context);
      final pad = 0.05 * size.height;
      return PopScope(
        canPop: widget.settings.setupDone && at == 0,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _go(-1);
        },
        child: Scaffold(
          body: DecoratedBox(
            decoration: backdropBase,
            child: Center(
              child: SizedBox(
                width: 0.86 * size.width,
                height: 0.82 * size.height,
                child: Glass(
                  radius: 28,
                  padding: EdgeInsets.all(pad),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 0.32 * size.width,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _Dots(at, steps.length),
                            const SizedBox(height: 10),
                            Text(
                              t('stepOf')
                                  .replaceAll('{n}', '${at + 1}')
                                  .replaceAll('{total}', '${steps.length}'),
                              style: settingsNote,
                            ),
                            Expanded(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Icon(
                                    icon,
                                    size: 36,
                                    color: const Color(0x8CFFFFFF),
                                  ),
                                  const SizedBox(height: 14),
                                  Text(
                                    title,
                                    style: TextStyle(
                                      fontSize: _at == _Step.welcome ? 44 : 30,
                                      fontWeight: FontWeight.w700,
                                      height: 1.15,
                                    ),
                                  ),
                                  const SizedBox(height: 10),
                                  // A long text on a small screen fades out
                                  // instead of pushing Continue off the card.
                                  Flexible(
                                    child: Text(
                                      help,
                                      overflow: TextOverflow.fade,
                                      style: const TextStyle(
                                        fontSize: 15,
                                        height: 1.4,
                                        color: Color(0xB3FFFFFF),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            SettingsRow(
                              title: t(last ? 'done' : 'continue'),
                              primary: true,
                              valueIcon: last
                                  ? Icons.check
                                  : Icons.arrow_forward,
                              focusNode: _continue,
                              onPressed: () => _go(1),
                            ),
                            if (skippable) ...[
                              const SizedBox(height: 6),
                              SettingsRow(
                                title: t('skip'),
                                onPressed: () => _go(1),
                              ),
                            ],
                          ],
                        ),
                      ),
                      SizedBox(width: pad),
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
                                spacing: 16,
                                children: [
                                  Focus(
                                    focusNode: _content,
                                    child: KeyedSubtree(
                                      // A new step's pane is a new one: the
                                      // last one's sign-ins end with it.
                                      key: ValueKey(_at),
                                      child: _pane(),
                                    ),
                                  ),
                                  // Outside the step's subtree, so the code
                                  // stays offered from one step to the next.
                                  if (_phone && _ipKnown)
                                    CompanionPane(
                                      widget.pairing,
                                      _ip,
                                      compact: true,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// Where the setup is: a dot a step, the current one long.
class _Dots extends StatelessWidget {
  final int at;
  final int count;
  const _Dots(this.at, this.count);

  @override
  Widget build(BuildContext context) => Row(
    spacing: 6,
    children: [
      for (var i = 0; i < count; i++)
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: i == at ? 22 : 8,
          height: 8,
          decoration: BoxDecoration(
            color: i <= at ? Colors.white : const Color(0x40FFFFFF),
            borderRadius: const BorderRadius.all(Radius.circular(4)),
          ),
        ),
    ],
  );
}

/// How to get a TMDB key, folded under one row: OK opens and closes it. Each
/// step takes focus, so the D-pad scrolls through the steps and their
/// pictures of TMDB's site.
class TmdbGuide extends StatefulWidget {
  const TmdbGuide({super.key});

  @override
  State<TmdbGuide> createState() => _TmdbGuideState();
}

const _tmdbSteps = [
  ('tmdbStep1', ['tmdb_1_join', 'tmdb_2_signup']),
  ('tmdbStep2', ['tmdb_3_settings']),
  ('tmdbStep3', ['tmdb_4_request']),
  ('tmdbStep4', ['tmdb_5_key']),
];

class _TmdbGuideState extends State<TmdbGuide> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => SettingsGroup(
    children: [
      SettingsRow(
        title: t('tmdbHowTo'),
        valueIcon: _open ? Icons.expand_less : Icons.expand_more,
        onPressed: () => setState(() => _open = !_open),
      ),
      if (_open)
        for (final (i, (text, pictures)) in _tmdbSteps.indexed)
          _GuideStep(i + 1, t(text), pictures),
    ],
  );
}

class _GuideStep extends StatefulWidget {
  final int n;
  final String text;
  final List<String> pictures;
  const _GuideStep(this.n, this.text, this.pictures);

  @override
  State<_GuideStep> createState() => _GuideStepState();
}

class _GuideStepState extends State<_GuideStep> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Focus(
    onFocusChange: (f) {
      setState(() => _focused = f);
      if (f) {
        Scrollable.ensureVisible(
          context,
          alignment: 0.1,
          duration: const Duration(milliseconds: 200),
        );
      }
    },
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        color: _focused ? const Color(0x1FFFFFFF) : const Color(0x00000000),
        border: Border.all(
          color: _focused ? const Color(0xCCFFFFFF) : const Color(0x00000000),
          width: 2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: const BoxDecoration(
                  color: Color(0x26FFFFFF),
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${widget.n}',
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Text(
                  widget.text,
                  style: const TextStyle(
                    fontSize: 15,
                    height: 1.4,
                    color: Color(0xD9FFFFFF),
                  ),
                ),
              ),
            ],
          ),
          for (final p in widget.pictures)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: AspectRatio(
                  aspectRatio: 5 / 3,
                  child: Image.asset(
                    'assets/setup/$p.webp',
                    fit: BoxFit.cover,
                    // The pane is under 500 dp wide; a TV draws at 2x.
                    cacheWidth: 1000,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
