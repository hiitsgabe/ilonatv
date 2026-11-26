import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';

/// The device's locale, such as `en_CA`; tests replace it.
@visibleForTesting
String Function() deviceLocale = () => Platform.localeName;

/// The country of [deviceLocale] (ISO 3166-1 alpha-2, upper case), else US.
String deviceCountry() =>
    RegExp(r'[_-]([A-Za-z]{2})(?=$|[_.@-])')
        .firstMatch(deviceLocale())
        ?.group(1)
        ?.toUpperCase() ??
    'US';

/// The app language for [deviceLocale]: `pt` for any Portuguese, else `en`.
String deviceLanguage() =>
    deviceLocale().toLowerCase().startsWith('pt') ? 'pt' : 'en';
