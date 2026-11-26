# Privacy and permissions

## What leaves the TV

Ilona TV has no cloud server, no analytics and no ads. The one thing it serves is the Companion: a small server on the TV, on port 8642, that answers only phones and computers you paired, and only on your local network. Your keys, accounts and settings stay in Ilona TV's private storage on the TV, and backup and device-to-device transfer are turned off for it. Ilona TV talks directly to these services, and only for the features you turn on:

| Service | For | With |
| --- | --- | --- |
| TMDB (`api.themoviedb.org`, `image.tmdb.org`) | Rows, details, search, where a title streams | Your API key |
| JustWatch (`apis.justwatch.com`, `images.justwatch.com`) | Your country's streaming services, genres, what is popular now | Only the country, language and picked services or genre |
| Open-Meteo (`api.open-meteo.com`, `geocoding-api.open-meteo.com`) | City search and the forecast | The city's coordinates |
| YouTube (`www.youtube.com` and its image hosts) | Home feed and history | The profiles you signed in |
| Stremio (`api.strem.io`, `link.stremio.com`, `v3-cinemeta.strem.io`, `images.metahub.space`) | Library, continue watching, popular titles, sports add-ons | Your account |
| ESPN (`site.api.espn.com`), TheSportsDB (`www.thesportsdb.com`) | Games and team artwork | The leagues you follow |
| Google Gemini (`generativelanguage.googleapis.com`) | The voice assistant | Your Gemini key |

**The voice assistant.** While it is up, it records the TV's microphone until you stop talking. The clip stays in memory, is never written to storage, and is sent with your Gemini key to Google's Gemini API. A short text prompt goes with it: the time and date, the language and, when a city is set, the city's name and weather. Without a key it sends nothing.

## Permissions

| Permission | Why |
| --- | --- |
| `INTERNET` | The services above. |
| `RECEIVE_BOOT_COMPLETED` | Launcher mode starts Ilona TV at boot. |
| Accessibility service | Launcher mode (see [launcher-mode.md](launcher-mode.md)). While it is on it can also undo a double power press, replace Alexa with Ilona TV's assistant, tap the first stream in Stremio when "Play the first stream" is on, and tap Force stop when you close an app from Processes. It keeps nothing it reads on screen. |
| `WRITE_SECURE_SETTINGS` (adb only) | Lets Ilona TV turn its own accessibility service on, on Fire TV. |
| `DUMP`, `PACKAGE_USAGE_STATS` (adb only) | Settings > Processes: what each app holds in memory. |
| `KILL_BACKGROUND_PROCESSES` | Processes: Close and Clean for apps in the background. |
| `RECORD_AUDIO` | The voice assistant only, asked for when you turn it on. |
| `READ_EXTERNAL_STORAGE` (Android 12 and lower), `READ_MEDIA_IMAGES` (13+) | Custom tile images: lists the pictures on the TV, asked for when the picker opens. No picture leaves the TV. |

The three adb-only permissions are granted once, by the companion's installer on Fire TV (which also allows restricted settings on Android 13+), or from a computer:

```sh
adb shell pm grant tv.ilona.app android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant tv.ilona.app android.permission.DUMP
adb shell pm grant tv.ilona.app android.permission.PACKAGE_USAGE_STATS
```

## The Companion phone app

The Ilona TV Companion (`tv.ilona.companion`) asks for three permissions:

| Permission | Why |
| --- | --- |
| `INTERNET` | Talking to the TV on your local network (and ADB, only while installing), and, in the installer, downloading Ilona TV from GitHub. |
| `CHANGE_WIFI_MULTICAST_STATE` | Finding Ilona TV on the network by its mDNS name. |
| `CAMERA` | Scanning the pairing QR code, asked for when the scanner opens. No picture is kept or sent. |

It stores, for each paired TV, only the host, port, name and token. It also keeps the ADB key it uses to talk to a TV in the app's private storage, excluded from backup and device transfer; a new phone makes a new key and the TV asks "Allow debugging?" again. It connects over ADB only in the installer. The installer asks GitHub's API for this repository's latest release (`api.github.com`, with the generic user agent `Ilona TV-Companion` and nothing about you), downloads the APK for the TV's CPU from it, and checks its SHA-256 before installing; nothing else leaves the phone.

On the TV, a content provider (`content://tv.ilona.app.pairing`) hands the pairing secret to the installer so the phone can pair without a QR code. It is guarded by `DUMP` and answers only the adb shell (or root), so no app on the TV can read it. Reading does not change the secret: a successful pairing with it renews it, and so does removing a phone in Settings > Companion. The same provider takes a settings import from the adb shell alone ([import.md](import.md)).

