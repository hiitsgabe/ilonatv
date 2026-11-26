# Development

## Build

Needs Flutter 3.47 (stable, Dart 3.13), the Android SDK and JDK 21 for Gradle. If your default JDK is newer, point `JAVA_HOME` at a JDK 21.

```sh
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

The APKs land in `build/app/outputs/flutter-apk/`: `app-armeabi-v7a-release.apk` (most Fire TV devices) and `app-arm64-v8a-release.apk`. `--target-platform` leaves out the x86_64 APK. The version code in `pubspec.yaml` must stay above 10000.

**Signing.** With an `android/key.properties`, release builds are signed with your key:

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=<alias>
storeFile=<path to the .jks, relative to android/app>
```

Without it they use the debug key, which differs on every machine, so an APK built elsewhere will not install over yours. `key.properties` and keystores are ignored by git.

## Tests

```sh
flutter analyze
flutter test
```

The sources are tested against canned answers in `test/fixtures/` (TMDB, JustWatch, Stremio, YouTube, Open-Meteo, ESPN), served by `fake()` and `fakePost()` in `test/fixtures.dart`. No test touches the network. The screens have widget tests driven by D-pad key events.

UI text goes through `t('key')` in `lib/i18n.dart`, in English and Portuguese; `test/i18n_test.dart` fails when one language misses a key.

## On a device

`adb shell input keyevent <code>` drives the remote from a computer: Up 19, Down 20, Left 21, Right 22, OK 23, Back 4, Home 3. On-device checks are listed in [verification.md](verification.md).

**Frame times.** A profile build (`flutter build apk --profile --split-per-abi --target-platform android-arm`) logs every frame over 17 ms with its build and raster times (`adb logcat -s flutter`). `adb shell dumpsys SurfaceFlinger --latency 'SurfaceView - app.elimor.app/app.elimor.app.MainActivity#0'` gives frame times without a build. Elimor forces Skia over Impeller in the manifest: on a Fire TV Edition's Mali-G52, Impeller took 21-22 ms per home frame, Skia 5-14.

**Memory.** Measure on a profile build; a debug build's memory is inflated by the JIT.

## Seeding an emulator

The fixtures can give an emulator its rows with no keys. Each source writes what it fetched to `files/cache/<name>.json` (`tmdb.json`, `stremio.json`, `youtube.json`), and a start shows those files at any age. On a debug build, run Elimor once so `files/cache` exists, then:

```sh
adb shell "run-as app.elimor.app sh -c 'cat > files/cache/tmdb.json'" < tmdb.json
```

To make such a file, run a source over the fixtures in a throwaway test (`TmdbSource(settings, Store(dir), fetch: fake(routes).call).refresh()` writes `dir/cache/tmdb.json`), or pull one from a debug build that has the keys:

```sh
adb exec-out run-as app.elimor.app cat files/cache/tmdb.json > tmdb.json
```

The YouTube row also needs enabled accounts in the preferences (`youtubeAccounts`), and "Continue watching" needs a `stremioAuthKey`.
