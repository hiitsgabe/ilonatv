import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'desktop/host.dart';
import 'i18n.dart';

import 'package:ilonatv_protocol/releases.dart';

import 'tv_client.dart';
import 'tvs.dart';
import 'ui/home_page.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final tvs = Tvs();
  await tvs.load();
  I18n.language = PlatformDispatcher.instance.locale.languageCode == 'pt'
      ? 'pt'
      : 'en';
  runApp(
    CompanionApp(
      tvs: tvs,
      updates: UpdateCheck(fetch: latestTag, own: appVersion),
    ),
  );
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key, required this.tvs, this.updates});

  final Tvs tvs;
  final UpdateCheck? updates;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder(
      valueListenable: accent,
      builder: (context, seed, _) => MaterialApp(
        title: t('appName'),
        debugShowCheckedModeBanner: false,
        theme: companionTheme(seed),
        // A window can be any width; the app keeps a phone's, centred.
        builder: isDesktop
            ? (context, child) => ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 480),
                    child: child,
                  ),
                ),
              )
            : null,
        home: HomePage(
          tvs: tvs,
          clientFor: (tv) => TvClient(tv.host, port: tv.port, token: tv.token),
          updates: updates,
        ),
      ),
    );
  }
}
