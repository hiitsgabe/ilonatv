import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'i18n.dart';

import 'package:ilonatv_protocol/releases.dart';

import 'tv_client.dart';
import 'tvs.dart';
import 'ui/home_page.dart';

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
    return MaterialApp(
      title: t('appName'),
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        fontFamily: 'Inter',
        scaffoldBackgroundColor: Colors.black,
        colorScheme: const ColorScheme.dark(
          primary: Colors.white,
          onPrimary: Colors.black,
          surface: Color(0x14FFFFFF),
        ),
        cardTheme: CardThemeData(
          color: const Color(0x2EFFFFFF),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
            side: const BorderSide(color: Color(0x66FFFFFF)),
          ),
        ),
      ),
      home: HomePage(
        tvs: tvs,
        clientFor: (tv) => TvClient(tv.host, port: tv.port, token: tv.token),
        updates: updates,
      ),
    );
  }
}
