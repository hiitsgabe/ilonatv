import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ilonatv/app.dart';

void main() {
  // The release workflow bumps both; the phone compares this with the latest release.
  test('kVersion is the pubspec version name', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final name = RegExp(r'^version: ([^+\s]+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1);
    expect(kVersion, name);
  });
}
