import 'package:flutter/foundation.dart';

class I18n {
  static String language = 'en';
}

String t(String key) =>
    _strings[I18n.language]?[key] ?? _strings['en']![key] ?? key;

@visibleForTesting
Set<String> i18nKeys(String language) => {...?_strings[language]?.keys};

const _strings = {
  'en': {
    'appName': 'IlonaTv Companion',
    'tagline': 'Your phone, the remote for IlonaTv.',
  },
  'pt': {
    'appName': 'IlonaTv Companion',
    'tagline': 'O seu telemóvel, o comando do IlonaTv.',
  },
};
