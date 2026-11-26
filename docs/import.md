# Importing settings over adb

Ilona TV takes its settings from a JSON file handed to it over adb, for moving from another build without typing keys and signing in again. Only the adb shell (or root) can hand it over: the provider is guarded by `DUMP` and turns away every other caller, so no app on the TV can.

```sh
adb shell content write --uri content://tv.ilona.app.pairing/import < settings.json
adb shell 'am force-stop tv.ilona.app && am start -n tv.ilona.app/.MainActivity'
```

The first command stores the file as `files/import/settings.json` (it appears only once adb has sent all of it); nothing changes yet. The next start of Ilona TV writes its keys into the settings, deletes the file, and then loads the settings as usual, so the upgrades of older settings apply (old home row keys, retired tile icons, the `elimor:apps` and `elimor:settings` tiles). `content write` reads standard input and is in Android 9 and later (Fire OS 7 and 8).

## The file

One JSON object, pref key to value. Each key given replaces that setting; keys left out keep their value. A key Ilona TV does not know, or a value of the wrong type, is skipped and logged by name (`adb logcat -s flutter`, never the value); a file that is not a JSON object imports nothing. The file is deleted either way.

| Type | Keys |
| --- | --- |
| bool | `setupDone`, `settingsTileDropped`, `fireTvMode`, `doublePowerFix`, `stremioAutoPlay`, `alexaBounce`, `fahrenheit`, `gamesBySport` |
| int | `assistantColor` (ARGB) |
| number | `weatherLat`, `weatherLon` |
| string | `language`, `country`, `tmdbKey`, `geminiKey`, `stremioAuthKey`, `stremioEmail`, `weatherCity`, `movieProvider`, `seriesProvider`, `youtubeProvider`, `youtubeDeviceId` |
| string of JSON | `tiles`, `youtubeAccounts`, `sports`, `homeRows`, `rowProviders`, `rowGenres`, `serviceApps`, `companionDevices`, `hiddenApps`, `recentSearches` |

The string-of-JSON keys are stored as the app stores them, a string holding JSON, and must read as their shape: `tiles` a list of `{"package", "icon"}`, `youtubeAccounts` a list of `{"refreshToken", "name"}`, `sports` a list of `{"league", "name"}`, `homeRows` a list of `{"key", "on"}`, `rowProviders` an object of numbers, `rowGenres`, `serviceApps` and `companionDevices` objects of strings, `hiddenApps` and `recentSearches` lists of strings.

`companionSecret` is never imported: the TV keeps its own. A tile's custom `image` is a path in the old build's files, which Ilona TV cannot read, so such a tile shows as a grey card until its image is chosen again.

```json
{
  "setupDone": true,
  "language": "pt",
  "tmdbKey": "…",
  "tiles": "[{\"package\":\"elimor:apps\",\"icon\":\"apps\"}]"
}
```
