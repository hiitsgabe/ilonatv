import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'i18n.dart';

void main() {
  I18n.language = PlatformDispatcher.instance.locale.languageCode == 'pt'
      ? 'pt'
      : 'en';
  runApp(const CompanionApp());
}

class CompanionApp extends StatelessWidget {
  const CompanionApp({super.key});

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
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                t('appName'),
                style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              Text(t('tagline')),
            ],
          ),
        ),
      ),
    );
  }
}
