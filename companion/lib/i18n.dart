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
    'installOnTv': 'Install IlonaTv on a TV',
    'pairWithCode': 'Pair with a code',
    'scanQr': 'Scan the QR on the TV',
    'typeCode': 'Type the code',
    'badCode': "That code didn't work. Check it on the TV, Settings > Companion.",
    'noTvs': 'No IlonaTv found on this network yet.',
    'installSoon': 'The installer is not ready yet.',
    'paired': 'Paired',
    'tapToPair': 'Tap to pair',
    'pairTitle': 'Pair with a TV',
    'chooseTv': 'Which TV?',
    'tvAddress': 'TV address, like 192.168.1.20',
    'codeHint': '6-digit code',
    'pairNow': 'Pair',
    'cantReach': "Can't reach the TV. Check it is on and on the same Wi-Fi.",
    'scanHint': 'Point the camera at the QR on the TV',
    'close': 'Close',
  },
  'pt': {
    'appName': 'IlonaTv Companion',
    'tagline': 'O seu telemóvel, o comando do IlonaTv.',
    'installOnTv': 'Instalar o IlonaTv numa TV',
    'pairWithCode': 'Parear com um código',
    'scanQr': 'Escanear o QR da TV',
    'typeCode': 'Digitar o código',
    'badCode': 'Esse código não funcionou. Confira na TV, em Ajustes > Companion.',
    'noTvs': 'Nenhum IlonaTv nesta rede ainda.',
    'installSoon': 'O instalador ainda não está pronto.',
    'paired': 'Pareada',
    'tapToPair': 'Toque para parear',
    'pairTitle': 'Parear com uma TV',
    'chooseTv': 'Qual TV?',
    'tvAddress': 'Endereço da TV, como 192.168.1.20',
    'codeHint': 'Código de 6 dígitos',
    'pairNow': 'Parear',
    'cantReach': 'Não consegui falar com a TV. Veja se está ligada e na mesma rede Wi-Fi.',
    'scanHint': 'Aponte a câmera para o QR da TV',
    'close': 'Fechar',
  },
};
