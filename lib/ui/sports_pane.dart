import 'package:flutter/material.dart';

import '../data/media.dart';
import '../data/sports.dart';
import '../disk_images.dart';
import '../i18n.dart';
import '../net.dart';
import '../settings.dart';
import 'settings_kit.dart';

/// The leagues of [kSportsLeagues], each with what of it is followed; OK
/// opens the league's page.
class SportsPane extends StatelessWidget {
  final Settings settings;
  final Fetch fetch;
  const SportsPane(this.settings, {this.fetch = getJson, super.key});

  String _value(String league) =>
      switch (settings.sports.where((f) => f.league == league).firstOrNull) {
        null => t('off'),
        SportsFollow(onlyTeams: true, :final teams) =>
          teams.length == 1
              ? t('oneTeam')
              : t('nTeams').replaceAll('{n}', '${teams.length}'),
        _ => t('allGames'),
      };

  @override
  Widget build(BuildContext context) => SettingsGroup(
    footer: t('sportsHelp'),
    children: [
      for (final (league, name) in kSportsLeagues)
        SettingsRow(
          title: name,
          value: _value(league),
          chevron: true,
          onPressed: () => pushSettingsPage(
            context,
            title: () => name,
            icon: Icons.sports_soccer_outlined,
            listen: settings,
            build: () => LeaguePane(settings, league, name, fetch: fetch),
          ),
        ),
    ],
  );
}

/// One league: Follow, Only my teams, then its teams from ESPN, each a check
/// row. Picking a team of a league not followed follows it for that team.
/// Every change saves.
class LeaguePane extends StatefulWidget {
  final Settings settings;
  final String league;
  final String name;
  final Fetch fetch;
  const LeaguePane(
    this.settings,
    this.league,
    this.name, {
    this.fetch = getJson,
    super.key,
  });

  @override
  State<LeaguePane> createState() => _LeaguePaneState();
}

class _LeaguePaneState extends State<LeaguePane> {
  List<GameTeam>? _teams;
  var _failed = false;

  /// The follow turned off on this page, so turning it back on keeps its teams.
  SportsFollow? _unfollowed;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final teams = parseTeams(await widget.fetch(teamsUri(widget.league)));
      if (mounted) setState(() => _teams = teams);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _retry() {
    setState(() => _failed = false);
    _load();
  }

  List<SportsFollow> get _all => widget.settings.sports;

  SportsFollow? get _follow =>
      _all.where((f) => f.league == widget.league).firstOrNull;

  bool get _full => _follow == null && _all.length >= kMaxSportsLeagues;

  /// [f] in place of the league's follow, at its place; null unfollows.
  Future<void> _set(SportsFollow? f) async {
    final i = _all.indexWhere((x) => x.league == widget.league);
    widget.settings.sports = [
      for (final (j, x) in _all.indexed)
        if (j != i) x else ?f,
      if (i < 0) ?f,
    ];
    await widget.settings.save();
  }

  void _toggleFollow() {
    if (_follow != null) {
      _unfollowed = _follow;
      _set(null);
    } else if (!_full) {
      _set(_unfollowed ?? SportsFollow(widget.league, widget.name));
    }
  }

  void _toggleOnly() {
    final f = _follow!;
    _set(
      SportsFollow(f.league, f.name, onlyTeams: !f.onlyTeams, teams: f.teams),
    );
  }

  void _toggleTeam(GameTeam team) {
    final f = _follow;
    if (f == null) {
      if (_full) return;
      _set(
        SportsFollow(
          widget.league,
          widget.name,
          onlyTeams: true,
          teams: [SportsTeam(team.id, team.name)],
        ),
      );
      return;
    }
    final picked = f.teams.any((x) => x.id == team.id);
    // Unticking the last of "only my teams" leaves nothing to show: unfollow.
    if (picked && f.onlyTeams && f.teams.length == 1) {
      _set(null);
      return;
    }
    _set(
      SportsFollow(
        f.league,
        f.name,
        onlyTeams: f.onlyTeams,
        teams: picked
            ? [
                for (final x in f.teams)
                  if (x.id != team.id) x,
              ]
            : [...f.teams, SportsTeam(team.id, team.name)],
      ),
    );
  }

  Widget _logo(String? url) => url == null
      ? const SizedBox()
      : Image(
          image: ResizeImage(DiskImage(url), width: 48),
          errorBuilder: (_, _, _) => const SizedBox(),
        );

  @override
  Widget build(BuildContext context) {
    final f = _follow;
    String onOff(bool on) => t(on ? 'on' : 'off');
    return settingsGroups([
      SettingsGroup(
        footer: _full
            ? t('sportsMax').replaceAll('{n}', '$kMaxSportsLeagues')
            : f != null
            ? t('onlyMyTeamsHelp')
            : null,
        children: [
          SettingsRow(
            title: t('follow'),
            value: onOff(f != null),
            onPressed: _toggleFollow,
          ),
          if (f != null)
            SettingsRow(
              title: t('onlyMyTeams'),
              value: onOff(f.onlyTeams),
              onPressed: _toggleOnly,
            ),
        ],
      ),
      SettingsGroup(
        header: t('teams'),
        footer: _failed
            ? t('networkError')
            : _teams == null
            ? '…'
            : null,
        children: [
          if (_failed)
            SettingsRow(
              leading: const Icon(Icons.refresh),
              title: t('checkAgain'),
              onPressed: _retry,
            ),
          for (final team in _teams ?? const <GameTeam>[])
            SettingsRow(
              leading: _logo(team.logo),
              title: team.name,
              valueIcon: f?.teams.any((x) => x.id == team.id) == true
                  ? Icons.check
                  : null,
              onPressed: () => _toggleTeam(team),
            ),
        ],
      ),
    ]);
  }
}
