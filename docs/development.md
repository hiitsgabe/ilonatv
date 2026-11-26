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

## Companion

The phone app is a separate Flutter project in `companion/` (package `ilonatv_companion`, app id `tv.ilona.companion`). It shares the TV's wire format with the app through `packages/ilonatv_protocol`. The TV's side is `lib/companion/` (server) and, for the installer, `PairingProvider.kt`.

The companion carries no TV APK: its installer downloads `ilonatv-<abi>.apk` from the latest GitHub Release (`companion/lib/releases.dart`), checks the SHA-256 GitHub reports for the asset (or the release's `SHA256SUMS`), then installs it. So a companion you build installs the latest *published* IlonaTv, not your local build; to try a local TV build, install it with adb.

`tool/build_companion.sh` builds the companion release APK and prints its path: `companion/build/app/outputs/flutter-apk/app-release.apk`. `JAVA_HOME` and `ANDROID_HOME` default to `~/.cache/elimor-toolchain/jdk` and `.../sdk` when unset, and flutter is taken from `~/.cache/elimor-toolchain/flutter/bin` when it is not on the `PATH`.

```sh
cd companion
flutter analyze
flutter test
```

## Releases

Two workflows in `.github/workflows/`:

- **CI** (`ci.yml`) runs on every pull request and push to `main`: `flutter analyze` and `flutter test` at the root, `dart test` in `packages/ilonatv_protocol`, and `flutter analyze` and `flutter test` in `companion/`. It builds nothing signed.
- **Build and Release** (`release.yml`) runs by hand. It bumps the patch version (0.6.9 goes to 0.7.0) and the build number in `pubspec.yaml` and `companion/pubspec.yaml` (one version for both apps), commits "chore: bump version to X" to `main`, tags `vX.Y.Z`, runs both test suites, builds the TV APKs (`ilonatv-armeabi-v7a.apk`, `ilonatv-arm64-v8a.apk`) and the companion (`ilonatv-companion.apk`), writes `SHA256SUMS`, and publishes a release with the commit subjects since the last release. Old releases are kept.

To cut a release: Actions > Build and Release > Run workflow, on `main`.

Release signing needs three repository secrets (Settings > Secrets and variables > Actions):

- `KEYSTORE64`: the release keystore (`.jks`), base64-encoded (`base64 -w0 release.jks`).
- `KEY_ALIAS`: the key's alias in it.
- `KEY_PASSWORD`: the password, used for both the keystore and the key.

The workflow writes `android/key.properties` and `companion/android/key.properties` from them. Without them (a fork, say) it warns and signs with the debug key. Keep the keystore safe: an APK signed with another key will not install over one signed with this.

## On a device

`adb shell input keyevent <code>` drives the remote from a computer: Up 19, Down 20, Left 21, Right 22, OK 23, Back 4, Home 3. On-device checks are listed in [verification.md](verification.md).

**Frame times.** A profile build (`flutter build apk --profile --split-per-abi --target-platform android-arm`) logs every frame over 17 ms with its build and raster times (`adb logcat -s flutter`). `adb shell dumpsys SurfaceFlinger --latency 'SurfaceView - tv.ilona.app/tv.ilona.app.MainActivity#0'` gives frame times without a build. IlonaTv forces Skia over Impeller in the manifest: on a Fire TV Edition's Mali-G52, Impeller took 21-22 ms per home frame, Skia 5-14.

**Memory.** Measure on a profile build; a debug build's memory is inflated by the JIT.

## Seeding an emulator

The fixtures can give an emulator its rows with no keys. Each source writes what it fetched to `files/cache/<name>.json` (`tmdb.json`, `stremio.json`, `youtube.json`), and a start shows those files at any age. On a debug build, run IlonaTv once so `files/cache` exists, then:

```sh
adb shell "run-as tv.ilona.app sh -c 'cat > files/cache/tmdb.json'" < tmdb.json
```

To make such a file, run a source over the fixtures in a throwaway test (`TmdbSource(settings, Store(dir), fetch: fake(routes).call).refresh()` writes `dir/cache/tmdb.json`), or pull one from a debug build that has the keys:

```sh
adb exec-out run-as tv.ilona.app cat files/cache/tmdb.json > tmdb.json
```

The YouTube row also needs enabled accounts in the preferences (`youtubeAccounts`), and "Continue watching" needs a `stremioAuthKey`.
