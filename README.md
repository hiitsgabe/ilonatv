# Elimor

A launcher for Android-based TVs with an Apple TV look: a dark home with a full-screen backdrop, a clock with the weather, a short row of app tiles you choose, and rows of movies, series and videos below, in a liquid-glass look like tvOS 26 (a glass dock behind the app row, glass pills and cards), with focus shown by a lift, a scale-up and a thin bright edge, and one row on screen at a time.

Flutter for the UI, a little Kotlin for what Android needs. One code base for Fire TV and Android TV / Google TV, one APK per CPU architecture, driven by the remote alone (D-pad, OK, Back). The interface is in English and Portuguese. Package `app.elimor.app`.

Elimor is an independent hobby project. It is not affiliated with, endorsed by or sponsored by any of the services it talks to; see [Disclaimer](#disclaimer).

## Features

- **Home.** A clock, the weather for your city (Open-Meteo, no key), a dock of up to five app tiles with painted icons or the apps' own, and content rows underneath. The backdrop rotates every 10 seconds or follows the focused card; the Highlight above the rows shows the focused title with its logo, details and a Watch button.
- **Movies and series** from TMDB: Trending movies, Trending series and Recommended (with a Stremio app chosen, the movie and series rows are Stremio's popular titles, with details from TMDB), plus search (Movies, Series and YouTube results; Top rated, Hidden gems and a genre of the day while the field is empty). Holding OK on a card counts down and plays the title's trailer.
- **Service and genre filters** on the two trending rows: Left from the first card brings up a service card, and one more Left a genre card. Up and Down pick one of your country's subscription services, a genre, or All; the row then shows what is popular on that pick in your country now (JustWatch's streaming charts, each title with TMDB's details) and its name gains the picks ("Trending · Movies · Netflix · Comedy"). A pick with nothing on it keeps the row's own titles. The picks are kept per row until Home clears them. The backdrop rotates your country's popular films and series from the same charts.
- **Continue watching** from a Stremio account, with TMDB details.
- **YouTube**: the home feed of each signed-in profile, mixed, and "YouTube · Continue watching" with progress bars.
- **Games**: today's and tomorrow's games of the leagues you follow, your teams first, live scores from ESPN.
- **Inputs**: on Fire TV Edition smart TVs, a row of the HDMI ports. A port opens full screen inside Elimor; a port with an HDMI-CEC device (a console, say) wakes it, and the remote's keys pass through to it.
- **Apps grid** with a Show/Hide switch per app, and a tile editor (choose app, choose icon, move, remove).
- **Custom tile images**: in the tile editor, Choose icon > Custom image… lists the pictures on the TV (PNG, JPEG, WebP, GIF or BMP). Elimor keeps its own copy, so the original can be deleted; pick Fill (the picture covers the card) or Centered (on glass or one of eight colours). To put a picture on the TV: `adb push picture.png /sdcard/Download/` from a computer, a file manager app copying it from a USB stick, or a file manager that receives files over the network.
- **Settings**: Home rows (each row on or off, and its order), Weather, Sports, Apps, Open with, Processes (what each app holds in memory, with Close and Clean), Accounts, Launcher mode, Language, TV settings shortcuts and About.
- **Launcher mode**: Home brings Elimor back instead of the system home, also on Fire TV, where the Amazon home cannot be replaced.
- **Voice assistant (optional, Fire TV)**: the remote's mic button opens Elimor's own assistant instead of Alexa. It answers spoken questions through Google Gemini with your own API key, and finds movies, series, videos and games.
- Everything caches to disk, so the home opens on its last data and works offline.

## Supported devices

Elimor needs Android 9 (API 28) or later. It has been used day to day on a small number of devices only.

| Device | Status |
| --- | --- |
| Fire TV Stick 4K (Fire OS 7, Android 9, 32-bit) | Tested: install, Launcher mode, boot, content rows, accounts. |
| Fire TV Edition smart TV (Fire OS 8, Android 11, 32-bit) | Tested: Launcher mode, HDMI inputs with CEC, frame timing. |
| Google TV / Android TV (Android 12 to 14) | Not tested on a real device. The UI and Launcher mode have only run on an Android 14 emulator. |
| Other Fire TV models, other Android TV boxes | Not tested. Reports are welcome. |

## Install from a release APK

You need a computer with `adb` ([Android platform-tools](https://developer.android.com/tools/releases/platform-tools)) on the same network as the TV.

1. On the TV, turn on ADB debugging (Fire TV: Settings > My Fire TV > Developer options; Android TV and Google TV: unlock Developer options by pressing the build entry in Settings' About screen seven times, then turn on debugging there). Note the TV's IP address (Fire TV: Settings > My Fire TV > About > Network).
2. Connect. The first time, the TV asks "Allow USB debugging?": tick "Always allow from this computer" and accept. Until then every command answers `device unauthorized`.

   ```sh
   TV=<tv-ip>:5555
   adb connect $TV
   adb -s $TV shell getprop ro.product.cpu.abilist
   ```

3. Pick the APK from the [Releases](../../releases) page by that list (if no release is published yet, follow [Build from source](#build-from-source) instead): with `arm64-v8a` in it, the `arm64-v8a` APK; with only `armeabi-v7a`, the `armeabi-v7a` APK. The Fire TV devices tested so far list only 32-bit ABIs.

   ```sh
   adb -s $TV install -r <path-to>/app-armeabi-v7a-release.apk
   ```

   Expect `Success`. `-r` keeps Elimor's data on an upgrade.

4. Fire TV only: grant the permissions that only adb can grant (see [Permissions](#permissions)). Elimor's Launcher mode and Processes panes show the same commands with the TV's address filled in.

   ```sh
   adb -s $TV shell pm grant app.elimor.app android.permission.WRITE_SECURE_SETTINGS
   adb -s $TV shell pm grant app.elimor.app android.permission.DUMP
   adb -s $TV shell pm grant app.elimor.app android.permission.PACKAGE_USAGE_STATS
   ```

5. Open it:

   ```sh
   adb -s $TV shell am start -n app.elimor.app/.MainActivity
   ```

An APK signed with a different key will not install over an existing one; uninstall first (this clears Elimor's settings and accounts).

## First run

A fresh install opens a setup wizard. Every step can be skipped and changed later in Settings; Back returns to the previous step. Settings > About > Run setup again starts it over.

1. **Welcome and language** (English or Portuguese; the default follows the TV).
2. **Location**: search your city for the weather. Its country also decides where streaming services are looked up. Choose °C or °F.
3. **TMDB key**: needed for the movie and series rows, posters and search.
4. **Where titles open**: a Stremio app, or "My streaming apps" with a service-to-app mapping (see [How titles open](#how-titles-open)).
5. **YouTube**: which app plays videos (the first installed app that opens YouTube links is preselected), and an optional sign-in.
6. **Stremio account**, only when a Stremio app was chosen.
7. **Sports**: leagues and teams to follow.
8. **The Home button**: Launcher mode, with the instructions for your platform.
9. **Done**: the dock gets tiles for the apps you chose, and the home appears.

## Accounts and keys

All of these are entered on the TV, in the wizard or in Settings > Accounts. Approvals happen on a phone; no password is ever typed on the TV.

- **TMDB key.** Make an account at [themoviedb.org](https://www.themoviedb.org), request a key at themoviedb.org/settings/api, and use the "API Key" (v3), not the "API Read Access Token". Settings > Accounts > TMDB: Edit, OK on the field to open the keyboard, type, Done, then Test ("Key works" or "Key rejected") and Save. Saving an empty field removes the key and its rows. Without a key the backdrop is a plain gradient and a hint under the weather points to Settings.
- **YouTube.** Settings > Accounts > YouTube > Add account. The TV shows a code; on a phone, open google.com/device, type it and approve. The TV then lists the profiles of that Google login (the account and its brand accounts): untick any to leave out, then Add. Each profile has a switch for the home's YouTube row. If YouTube signs a profile out, its switch becomes "Sign in again". The code runs out after 30 minutes.
- **Stremio.** Settings > Accounts > Stremio > Log in with your phone. Scan the QR (or open link.stremio.com and type the code) and approve; the TV logs in within a few seconds. Log out clears it and drops the row. The entry shows only when a Stremio app is chosen or an account is already signed in.
- **Gemini key** (voice assistant only). Shown in Accounts once "Mic button opens Elimor" is on in Launcher mode.

**What is stored where.** Settings, the TMDB and Gemini keys, the YouTube refresh tokens and the Stremio `authKey` with its email are kept in Elimor's private app storage (`shared_preferences`). Responses and pictures are cached under Elimor's files directory (pictures up to 64 MB). Backup is off (`android:allowBackup="false"`, and data extraction rules that also exclude device-to-device transfer), so none of it leaves the TV with a device backup or transfer. Nothing is sent anywhere except the services listed in [Privacy](#privacy).

## How titles open

Settings > Open with, separately for movies, series and YouTube.

- **A Stremio app.** Any installed app that answers `stremio:` links is offered. A title opens at its page (`stremio:///detail/...`). With the official Android TV build (`com.stremio.one`), "Play the first stream" can also start the first stream for you; this uses the accessibility service and needs Launcher mode.
- **My streaming apps.** Elimor asks TMDB where the title streams in your country (the watch-provider data comes from JustWatch) and launches the installed app of the first service you mapped that has it. Settings > Open with > Streaming services lists your country's subscription services as JustWatch lists them; each suggests an installed app by name, and OK lets you pick any app or None. In this mode the movie and series rows show what is popular now on your mapped services (JustWatch's charts, falling back to TMDB's trending), so they show what you can actually open, and the Highlight's button reads "Watch on <service>".

  **Limit:** TMDB gives no deep links into the services' apps, so Elimor can only launch the app on its own home; you then find the title there.
- **YouTube**: the chosen app, or, with none chosen, whatever app Android picks for YouTube links. Trailers open the same way.

When nothing can open a title, the home says so.

## Sports

Settings > Sports (or the wizard) lists about two dozen leagues: the main European, American and South American football (soccer) leagues and cups, the NBA, WNBA, NFL, NHL and MLB. OK on a league opens its page: Follow, Only my teams, and the league's teams to tick. Up to 8 leagues can be followed. The games row shows today's and tomorrow's games, your teams first, then live games, then by start time; it refreshes every 5 minutes around live games, otherwise every 30.

Scores come from ESPN's public site API, which is undocumented and may change. Opening a game works only with a Stremio account whose add-ons include a sports catalog naming both teams, and a Stremio app chosen for movies or series; otherwise the game is shown but does not open.

## Launcher mode

Off by default. When it is on, Home brings Elimor back with a snapshot of the home (the curtain) covering the system's home until Elimor is in front, and Home from a row or from Settings puts the home back at its top. The mode also starts Elimor at boot. Extra Fire TV options in the same pane: "Remote sends power twice" (for remotes that send power over IR and Bluetooth at once: it undoes an off-then-on; turn the TV on with any other button) and "Mic button opens Elimor".

### Fire TV

Opening Elimor once puts it under "Recently used apps" on the Amazon home. Pinning it to the favorites bar of the Amazon home works too. Launcher mode clicks that tile, so one of the two must hold.

In Elimor, go to Settings > Launcher mode and switch it On. Fire OS lists no third-party accessibility service in its settings, so Elimor enables its own, which takes a permission only adb can grant. The pane shows two commands to run once from the computer, with the TV's address filled in: `adb connect`, and this one:

```sh
adb -s $TV shell pm grant app.elimor.app android.permission.WRITE_SECURE_SETTINGS
```

Then press "Check again" on the pane: the status line reads "Accessibility service: on". From then on the switch turns the service on and off by itself, and while it is On, Elimor puts the service back at boot and when it starts if it has left the list (after a Fire OS update, say). `pm revoke` with the same arguments takes the permission back.

What the switch does, to check it or to undo it by hand: On is the two `put`s below, with `<list>` standing for what `get` prints (`put` replaces the whole list, so the other services stay in front of Elimor's entry, separated by `:`; with an empty list, Elimor's entry alone):

```sh
adb -s $TV shell settings get secure enabled_accessibility_services
adb -s $TV shell settings put secure enabled_accessibility_services <list>:app.elimor.app/.HomeWatcher
adb -s $TV shell settings put secure accessibility_enabled 1
```

Off puts the list back without Elimor's entry. To clear the list instead (this drops every accessibility service, not only Elimor's):

```sh
adb -s $TV shell 'settings put secure enabled_accessibility_services ""'
```

Why this exists: the Amazon home is protected, so it always wins the Home button, and for 5 s after Home Android holds back activity starts from background apps (the app-switch lock). Launcher mode gets around both: on Home, the service covers the screen with a snapshot of Elimor (the curtain) and clicks Elimor's tile on the Amazon home, which the lock does not hold back.

### Google TV and Android TV

None of this has been tried on a real Google TV device yet. Reportedly, Google TV never shows a default-launcher chooser and always sends Home to its own launcher, so the procedure goes in steps; stop at the first one that works. [docs/verification.md](docs/verification.md) has the checks for a first run.

1. Install the `arm64-v8a` APK and press Home. If the system asks "Complete action using", choose Elimor and "Always". Done.
2. No chooser: Launcher mode, with no adb. It is the same service as on the Fire TV, and `com.google.android.apps.tv.launcherx` is in its list of home packages. In Elimor, go to Settings > Launcher mode and switch it On: the system's accessibility settings open; turn Elimor on there. On Android 13+ an accessibility service installed by sideload shows greyed out until restricted settings are allowed for the app: "Open app info", on the Launcher mode pane, opens the screen for that ("Allow restricted settings"); then "Open accessibility settings", on the same pane, leads back. If App info offers no such option, this allows it over adb:

   ```sh
   adb shell appops set app.elimor.app ACCESS_RESTRICTED_SETTINGS allow
   ```

3. Alternative, over adb: disable the Google TV launcher and `setupwraith` (the second package re-enables the first if it is left on). Home then resolves through the HOME category and lands on Elimor with no extra hop.

   ```sh
   adb shell pm disable-user --user 0 com.google.android.apps.tv.launcherx
   adb shell pm disable-user --user 0 com.google.android.tungsten.setupwraith
   ```

   Reversible with `adb shell pm enable <package>`, for both packages. A Google update may revert it, and the remote's YouTube button may stop working.

## Permissions

| Permission | Why |
| --- | --- |
| `INTERNET` | The content sources listed under [Privacy](#privacy). |
| `RECEIVE_BOOT_COMPLETED` | Launcher mode starts Elimor at boot. |
| Accessibility service (`HomeWatcher`) | Launcher mode: on Home, draws the curtain, holds back the remote's arrow keys meanwhile and brings Elimor back. With their options on, it also undoes a double power press and replaces Alexa's window with Elimor's assistant. While the service is on (Launcher mode turns it on), it also taps the first stream in the Stremio app when "Play the first stream" is on, and taps Force stop in the system settings when you close an app from Processes. It keeps nothing it reads on screen. |
| `WRITE_SECURE_SETTINGS` (adb only) | Lets the Launcher mode switch enable Elimor's own accessibility service on Fire TV, which has no settings screen for it. |
| `DUMP` and `PACKAGE_USAGE_STATS` (adb only) | Settings > Processes: what each app holds in memory (`dumpsys activity processes` needs both). |
| `KILL_BACKGROUND_PROCESSES` | Processes: Close and Clean for apps in the background. |
| `RECORD_AUDIO` | The voice assistant only. Asked for only when "Mic button opens Elimor" is on. |
| `READ_EXTERNAL_STORAGE` (Android 12 and lower), `READ_MEDIA_IMAGES` (Android 13+) | Custom tile images: lists the pictures on the TV. Asked for only when the picker opens. The thumbnails and the copy are made on the TV; no picture leaves it. |

**What the voice assistant sends.** While the assistant is up, it records the TV's microphone until you stop talking. The clip is kept in memory only, never written to storage, and sent with your own Gemini key to Google's Gemini API (`generativelanguage.googleapis.com`), together with a text prompt that holds the current time and date, the language and, when a city is set, the city's name and current weather. Titles it finds are then looked up with your TMDB key. Without a Gemini key it answers with a "no key" notice and sends nothing.

## Build from source

Needs Flutter 3.47 (stable channel, Dart 3.13), the Android SDK and JDK 21 for Gradle. If your default JDK is newer, point `JAVA_HOME` at a JDK 21 for the build.

```sh
flutter pub get
flutter build apk --release --split-per-abi --target-platform android-arm,android-arm64
```

`--target-platform` leaves out the x86_64 APK that `--split-per-abi` would add. The APKs land in `build/app/outputs/flutter-apk/` (`app-armeabi-v7a-release.apk`, `app-arm64-v8a-release.apk`). The version code in `pubspec.yaml` must stay above 10000.

**Signing.** With an `android/key.properties`, release builds are signed with your key:

```properties
storePassword=<password>
keyPassword=<password>
keyAlias=<alias>
storeFile=<path to the .jks, relative to android/app>
```

Without it they are signed with the debug key, which differs on every machine, so an APK built elsewhere will not install over it. `key.properties` and keystores are ignored by git.

## Development

```sh
flutter analyze
flutter test
```

The tests cover settings, i18n, the host channel, the network and cache helpers, the sources with their parsers, the providers, and screens as widget tests (the home's focus paths and one-row layout, search, the content rows, the settings panes, the setup wizard). The sources are tested against canned service answers in `test/fixtures/` (TMDB, JustWatch, Stremio, YouTube, Open-Meteo and ESPN JSON), served by `fake()` and `fakePost()` in `test/fixtures.dart`; no test touches the network.

UI checks can run on an Android emulator locked to landscape; with no TV system image it only approximates a TV. `adb shell input keyevent 20` drives the D-pad from the computer (Down 20, Up 19, Left 21, Right 22, OK 23, Back 4, Home 3).

Frame times on a TV: a profile build (`flutter build apk --profile --split-per-abi --target-platform android-arm`, installed over the release one) logs every frame over 17 ms with its build and raster times (`adb logcat -s flutter`, lines `frame N ms: build B, raster R`). `adb shell dumpsys SurfaceFlinger --latency 'SurfaceView - app.elimor.app/app.elimor.app.MainActivity#0'` gives the presented frames' times without a build. Elimor forces Skia over Impeller in the manifest: on a Fire TV Edition's Mali-G52 GPU, Impeller took 21-22 ms per home frame, Skia 5-14.

**Seeding an emulator.** The same fixtures give an emulator its rows with no keys. A source writes what it fetched to `files/cache/<name>.json` (`tmdb.json`, `stremio.json`, `youtube.json`), and a start shows those files at any age. On a debug build, where `run-as` works, seed them: run Elimor once so `files/cache` exists, then, from the directory that holds the file:

```sh
adb shell "run-as app.elimor.app sh -c 'cat > files/cache/tmdb.json'" < tmdb.json
```

To make such a file, run a source over the fixtures in a throwaway test (`TmdbSource(settings, Store(dir), fetch: fake(routes).call).refresh()` writes `dir/cache/tmdb.json`, the way the unit tests build their sources), or pull one from a debug build that has the keys:

```sh
adb exec-out run-as app.elimor.app cat files/cache/tmdb.json > tmdb.json
```

With no key set, the TMDB rows then show from their cache, with a hint under the weather asking for the TMDB key. The YouTube row also needs its enabled accounts in the preferences (`youtubeAccounts`), and "Continue watching" needs a `stremioAuthKey`, or the row is dropped at start. A profile build is debuggable too, and it is the one to measure memory on: a debug build's memory is inflated by the JIT.

UI text goes through `t('key')` in `lib/i18n.dart`, in English (`en`) and Portuguese (`pt`); add both when adding a string (`test/i18n_test.dart` checks). On-device checks are in [docs/verification.md](docs/verification.md).

## Known limitations

- Streaming-apps mode opens the service's app on its own home, not at the title (TMDB has no app deep links).
- After "All settings", Launcher mode ignores the Amazon home until Home is pressed: Back out of the grid, or the TV sleeping and waking there, leaves the Amazon home up until then.
- The tile click needs Elimor under "Recently used apps" or in the favorites bar of the Amazon home; without the tile, the relaunch waits for the 5 s lock.
- Force-stopping Elimor removes the accessibility service from the enabled list. With the `pm grant` and the switch On, Elimor puts it back the next time it starts; on the Fire TV the grant is the only way. On Google TV without the grant, turn it on again in the system's accessibility settings.
- On Android 13+ the task-to-front transition can show the launcher for about 200 ms, and Android 12+ shows the system splash fade on a cold start (both seen on the emulator).
- The editor dialogs fade out after a Home press.
- An app installed or removed outside Elimor shows on the next resume, but an updated app keeps its old icon until Elimor restarts.
- Removing the TMDB key also deletes that key's rows and cache.
- The YouTube, Stremio, JustWatch and ESPN endpoints are unofficial and can change or stop working without notice.
- Only English and Portuguese.

## Privacy

Elimor has no server, no analytics and no ads. It talks directly to:

- TMDB (`api.themoviedb.org`, `image.tmdb.org`), with your key: rows, details, search, watch providers.
- JustWatch (`apis.justwatch.com`, `images.justwatch.com`), no key and no account: your country's streaming services, its genre names and what is popular there now. Each request carries only the country, the language and the picked services or genre.
- Open-Meteo (`api.open-meteo.com`, `geocoding-api.open-meteo.com`): the city search and its forecast.
- YouTube (`www.youtube.com` and its image hosts), signed in with the profiles you added.
- Stremio (`api.strem.io`, `link.stremio.com`, `v3-cinemeta.strem.io`, `images.metahub.space`), with your account.
- ESPN (`site.api.espn.com`) and TheSportsDB (`www.thesportsdb.com`, team artwork) for the leagues you follow.
- Google Gemini (`generativelanguage.googleapis.com`), only for the voice assistant, with your key.

## Disclaimer

Elimor is not affiliated with, endorsed by or sponsored by YouTube or Google, Stremio, TMDB, JustWatch, ESPN, TheSportsDB, Open-Meteo, Amazon, Netflix, or any other service, app or console maker it mentions or opens. It uses some services through unofficial, undocumented interfaces (the YouTube TV sign-in and feeds, Stremio's account and add-on endpoints, JustWatch's GraphQL API, the one its own website uses, and ESPN's site API), which may break or be withdrawn at any time; use them according to each service's terms. Elimor hosts, provides and links to no video content of its own: it opens apps and Stremio add-ons that you install yourself, and you are responsible for using only content you have the right to watch. All product names, logos, trademarks and the console wordmarks shown on the inputs' cards belong to their respective owners and are used only to identify the device or service.

This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. The TMDB logo is shown in Settings > About.

Where-to-watch data is provided by [JustWatch](https://www.justwatch.com), through TMDB; the streaming services list, the genres and the streaming charts come from JustWatch directly.

## Licence

Copyright (C) 2026 hiitsgabe and the Elimor contributors.

Elimor is free software: you can redistribute it and/or modify it under the terms of version 3 of the [GNU General Public License](LICENSE) as published by the Free Software Foundation (SPDX: `GPL-3.0-only`). The bundled Inter font is under the SIL Open Font License (`assets/fonts/LICENSE.txt`).
