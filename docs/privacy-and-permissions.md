# Privacy and permissions

## What leaves the TV

Elimor has no server, no analytics and no ads. Your keys, accounts and settings stay in Elimor's private storage on the TV, and backup and device-to-device transfer are turned off for it. Elimor talks directly to these services, and only for the features you turn on:

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
| `RECEIVE_BOOT_COMPLETED` | Launcher mode starts Elimor at boot. |
| Accessibility service | Launcher mode (see [launcher-mode.md](launcher-mode.md)). While it is on it can also undo a double power press, replace Alexa with Elimor's assistant, tap the first stream in Stremio when "Play the first stream" is on, and tap Force stop when you close an app from Processes. It keeps nothing it reads on screen. |
| `WRITE_SECURE_SETTINGS` (adb only) | Lets Elimor turn its own accessibility service on, on Fire TV. |
| `DUMP`, `PACKAGE_USAGE_STATS` (adb only) | Settings > Processes: what each app holds in memory. |
| `KILL_BACKGROUND_PROCESSES` | Processes: Close and Clean for apps in the background. |
| `RECORD_AUDIO` | The voice assistant only, asked for when you turn it on. |
| `READ_EXTERNAL_STORAGE` (Android 12 and lower), `READ_MEDIA_IMAGES` (13+) | Custom tile images: lists the pictures on the TV, asked for when the picker opens. No picture leaves the TV. |

The three adb-only permissions are granted once from a computer:

```sh
adb shell pm grant app.elimor.app android.permission.WRITE_SECURE_SETTINGS
adb shell pm grant app.elimor.app android.permission.DUMP
adb shell pm grant app.elimor.app android.permission.PACKAGE_USAGE_STATS
```
