<div align="center">

# Ilona TV

**A calm, beautiful home screen for Fire TV and Google TV.**

Your apps, what to watch next and today's games on one screen, in a liquid-glass look,<br>
driven by the remote alone.

[![Licence: GPL-3.0](https://img.shields.io/badge/licence-GPL--3.0-blue)](LICENSE)
![Fire TV and Android TV](https://img.shields.io/badge/Fire%20TV%20%C2%B7%20Android%20TV-Android%209%2B-3DDC84)
![Flutter](https://img.shields.io/badge/built%20with-Flutter-02569B)

<img src="docs/images/tv-home.webp" alt="Ilona TV's home screen on a Fire TV Edition TV" width="900">

</div>

## Why Ilona TV

The stock TV homes push ads and whatever their store wants you to watch. Ilona TV shows **your** apps and **your** things to watch, and gets out of the way.

- **Rows that matter.** Trending movies and series, recommendations, Continue watching from Stremio, your YouTube feed, and live games from the leagues you follow, with your teams first.
- **Opens where you watch.** A title opens in Stremio, or in whichever of *your* streaming apps carries it in your country: Netflix, Prime Video, Disney+, Max and the rest.
- **Filter by service and genre.** Press Left on a row to see what's popular right now on one service, or in one genre.
- **Your dock, your way.** Up to five app tiles, each with a painted icon, the app's own icon or a picture of your own.
- **Takes over the Home button**, even on Fire TV, where the Amazon home can't normally be replaced.
- **Set up in minutes.** A first-run wizard walks you through everything. Sign-ins happen on your phone, so there's no typing passwords with a remote.
- **Your phone as a remote.** The [Ilona TV Companion](#phone-remote-and-installer) pairs with the QR code in Settings > Companion, for searching, watching and typing on your phone instead of the remote.
- **Private.** No cloud server, no account, no analytics. Everything stays on the TV.

Plus the weather, the TV's HDMI inputs with console control over HDMI-CEC (Fire TV Edition TVs), a voice assistant powered by your own Gemini key (Fire TV), and English and Portuguese.

## The first run

A short setup on the TV gets everything in place, and anything that needs typing can be done from your phone.

| | |
| :---: | :---: |
| <img src="docs/images/setup-welcome.webp" alt="Welcome step with the pairing QR code"> | <img src="docs/images/setup-tmdb.webp" alt="Step-by-step guide to a TMDB key"> |
| **Welcome**: pick the language, or scan the QR to set up from your phone | **TMDB key**: a guide with pictures for every step |
| <img src="docs/images/setup-titles.webp" alt="Choosing where titles open"> | <img src="docs/images/setup-sports.webp" alt="Picking leagues and teams"> |
| **Where titles open**: Stremio, or your own streaming apps | **Sports**: follow a league or just your teams |

## Phone remote and installer

The Ilona TV Companion is an Android app that does the computer steps below from your phone, then stays on as a remote. It also runs on a Mac or a Windows PC: see [Companion on a computer](#companion-on-a-computer).

- **Install** Ilona TV on a Fire TV: it finds the TV on your Wi-Fi, asks for the "Allow debugging?" prompt, downloads the right APK from the latest [release](../../releases) (checking its SHA-256), installs it, grants the permissions Launcher mode and Processes need, and starts it.
- **Pair** with the QR code or the code from Settings > Companion. Home lists your paired TVs with a live status dot and the Ilona TVs found on the Wi-Fi; with exactly one paired TV online, it opens its remote straight away.
- **Remote:** a four-way D-pad with OK (hold an arrow to repeat), or a swipe pad if you pick Swipe in the ⋮ menu; Back, Home and Keyboard; volume, mute and play/pause, which hide on a TV that has no way to do them. While the remote is open, the phone's volume buttons change the TV's volume. Tap the TV's name at the top to switch TVs, add one or forget this one. Vibration can be turned off in the ⋮ menu.
- **Explore:** search and the TV's rows in one tab, with filters for movies, series and YouTube. Watch names the TV and takes you back to the remote.
- **Type on the TV:** Keyboard sends text from your phone into the field selected on the TV, in any app (through the accessibility service Launcher mode uses), and fills in the TMDB key and city during the setup; it opens by itself when the setup asks.
- The Companion takes on the accent colour picked on the TV.
- **Updates:** once per launch it checks the latest release and says when the Companion, or the TV you are controlling, has a newer version; Update on the remote runs the installer again. Both apps also update themselves from About (Settings > About on the TV, the info button on the Companion's home): Check for updates, then Update downloads the release's APK, checks its SHA-256 and hands it to the system installer.

Download `ilonatv-companion.apk` from the [Releases](../../releases) page, sideload it on your phone, then choose "Install Ilona TV on a TV". To build it yourself, see [development](docs/development.md#companion).

Before you start, turn on ADB debugging on the TV (see step 1 of Get started, with video walkthroughs). The phone installer works on Fire TV and on Android TV devices that offer ADB network debugging on port 5555. Google TV and Android 11+ only offer "Wireless debugging", which needs pairing from a computer: use the Companion on a computer, or follow Get started below. Once Ilona TV is installed you can turn ADB debugging off; the remote uses it only for the keys the TV can't send itself while another app is in front (the D-pad below Android 13, and every key without Launcher mode's accessibility service).

### Companion on a computer

The same Companion runs on macOS and Windows, with the same remote, Explore, typing and installer. Download `ilonatv-companion-macos.zip` or `ilonatv-companion-windows.zip` from the [Releases](../../releases) page and unzip it.

- **macOS:** move `Ilona TV Companion.app` to Applications. The app is not signed, so the first time, right-click it and choose Open, then Open again. If macOS still refuses, open System Settings > Privacy & Security and click Open Anyway next to Ilona TV Companion. When macOS asks to find devices on your local network, choose Allow: that is how it finds your TVs.
- **Windows:** open the `Ilona TV Companion` folder and run `ilonatv_companion.exe`. The app is not signed, so SmartScreen may say "Windows protected your PC": click More info, then Run anyway. If Windows Firewall asks, allow it on private networks so it can find your TVs.

What differs from the phone:

- **Pairing** is with the code from Settings > Companion; there is no QR scanning. If your TV doesn't show up by itself, type its IP address next to the code.
- **adb** comes from Google. The Companion can't include it, because Google's licence doesn't allow passing it on. The first time the installer (or a remote key that needs ADB) needs it, the Companion uses the `adb` already on your computer if there is one (for Wireless debugging pairing it must be platform-tools 30 or newer); otherwise it asks before downloading Google's [Android SDK Platform-Tools](https://developer.android.com/studio/releases/platform-tools) (about 10 to 17 MB) into its own folder (`~/Library/Application Support/tv.ilona.companion` on a Mac, `%LOCALAPPDATA%\Ilona TV Companion` on Windows). It takes the archive named in Google's SDK repository manifest and checks its SHA-1 before unpacking it. By downloading it you agree to [Google's terms](https://developer.android.com/studio/releases/platform-tools).
- **Google TV and Android 11+** install through Wireless debugging: the installer shows where to turn it on, then asks for the pairing address and code from "Pair device with pairing code", and the IP address and port of the Wireless debugging screen.
- **Keyboard:** while the remote is in front, the arrow keys, Enter and Esc (or Backspace) are the D-pad, OK and Back.
- **Updates:** the banner and About open the release page; download the new zip from there.

## Get started

**You need:** a Fire TV, Google TV or Android TV device on Android 9 or later, a computer on the same network, and a free [TMDB](https://www.themoviedb.org) account for the movie and series rows. The setup on the TV shows how to get the TMDB key.

1. **Turn on debugging on the TV.**
   - *Fire TV:* Settings > My Fire TV > Developer options > ADB debugging. If Developer options is missing, open Settings > My Fire TV > About and press OK on the device name seven times. Video walkthroughs: [unlocking Developer options](https://www.youtube.com/watch?v=_Ixo7wR9njU) and [turning on ADB debugging](https://www.youtube.com/watch?v=xHktMEhgrtU).
   - *Google TV / Android TV:* Settings > System > About, press OK on "Android TV OS build" seven times, then Settings > System > Developer options > USB debugging.

   Then note the TV's IP address from its network settings.

2. **Install** [adb](https://developer.android.com/tools/releases/platform-tools) on the computer and connect. Accept the "Allow debugging?" prompt on the TV.

   ```sh
   adb connect <tv-ip>:5555
   adb shell getprop ro.product.cpu.abilist   # arm64-v8a? use ilonatv-arm64-v8a.apk; otherwise ilonatv-armeabi-v7a.apk
   ```

3. **Install Ilona TV** from the [Releases](../../releases) page (`ilonatv-armeabi-v7a.apk` fits most Fire TV devices; `SHA256SUMS` lists the checksums). To build it yourself, see [development](docs/development.md#build).

   ```sh
   adb install -r ilonatv-armeabi-v7a.apk
   adb shell am start -n tv.ilona.app/.MainActivity
   ```

4. **Follow the setup on the TV.** Every step can be skipped and changed later in Settings.

To make Home always bring you back to Ilona TV, turn on **Launcher mode** in Settings. On Fire TV that needs one more adb command, which the screen shows you. Details are in [docs/launcher-mode.md](docs/launcher-mode.md).

## How titles open

Pick this in the setup or in Settings > Open with, separately for movies and series.

| | **Stremio app** | **My streaming apps** |
| --- | --- | --- |
| A title opens | On its page in Stremio, or straight into the first stream | In the installed app of a service that has it in your country |
| The rows show | Stremio's popular titles, Continue watching | What's popular now on the services you mapped |
| You need | A Stremio app; an account for Continue watching | A TMDB key; your services mapped to their apps |

Streaming apps open on their own home, not at the title: the services don't publish links into their apps. Videos and trailers open in the YouTube app you choose; SmartTube and the official app both work.

## Tested TVs

| Device | Model | System | Status |
|---|---|---|---|
| [TCL 75" M7LF](https://www.bestbuy.ca/en-ca/product/tcl-75-m7lf-series-4k-uhd-hdr-mini-led-fire-tv-smart-tv-75m7lf-2026-great-for-movies-gaming/19972888) Mini-LED Fire TV (4K, MediaTek MT5896) | `75M7LF` (`AFTDEC012E`) | Fire OS 8.1.8.6 (Android 11) | Used every day: launcher, Companion, remote, sports rows |
| Fire TV Stick 4K | | Fire OS 7 (Android 9) | Used every day |

Google TV and other Android TV devices should work but haven't been tried on real hardware yet. If you run Ilona TV on another device, please open an issue with its model (Settings > My Fire TV > About, or `adb shell getprop ro.product.model`) so it can be added here.

## FAQ

<details>
<summary><b>Do I need Stremio?</b></summary>

No. Choose "My streaming apps" and Ilona TV works with the apps you already have. Stremio adds Continue watching, and lets games open in a sports add-on.
</details>

<details>
<summary><b>Why does it need adb?</b></summary>

To install an app that isn't in the store, and, on Fire TV, to grant the one permission Launcher mode needs. Ilona TV shows the exact commands on screen. After setup you can turn debugging off again.
</details>

<details>
<summary><b>Will it work on my device?</b></summary>

See [Tested TVs](#tested-tvs). Google TV and other Android TV devices should work but haven't been tried on real hardware yet. Reports are very welcome.

Fire TV devices that run Amazon's Vega OS instead of Fire OS (such as the Fire TV Stick 4K Select) don't run Android apps, so Ilona TV can't be installed on them. See [AFTVnews' list of Fire TVs without sideloading](https://www.aftvnews.com/these-are-the-fire-tvs-that-dont-support-sideloading-or-downloader-due-to-vega-os-replacing-fire-os/).
</details>

<details>
<summary><b>Is there a phone app?</b></summary>

Yes, the [Ilona TV Companion](#phone-remote-and-installer) for Android, which also runs on a [Mac or Windows PC](#companion-on-a-computer). It talks to the TV only on the local network, never over the internet, and Ilona TV answers only phones you paired. Settings > Companion shows the QR code and the code to pair with, and lists the paired phones, each with Remove.
</details>

<details>
<summary><b>How do I put my own picture on an app tile?</b></summary>

Copy the picture to the TV (`adb push picture.png /sdcard/Download/`, a USB stick or a file manager app). Then, in the tile editor, choose Choose icon > Custom image…, and pick Fill or Centered on a colour.
</details>

<details>
<summary><b>How do I undo it?</b></summary>

Turn Launcher mode off, or simply uninstall Ilona TV. On Google TV, if you disabled the stock launcher, `adb shell pm enable` it again (see [docs/launcher-mode.md](docs/launcher-mode.md)).
</details>

## More

- [Launcher mode](docs/launcher-mode.md): how Home is taken over on each platform, and its limits.
- [Privacy and permissions](docs/privacy-and-permissions.md): every service Ilona TV talks to, and why each permission is there.
- [Development](docs/development.md): building, signing, tests and profiling.

## Disclaimer

Ilona TV is an independent project, not affiliated with or endorsed by YouTube, Google, Stremio, TMDB, JustWatch, ESPN, Amazon, Netflix or any other service it opens or talks to. Some of them are used through unofficial interfaces that may stop working at any time; use each according to its terms. Ilona TV provides no video content: it opens the apps and add-ons you install, and you're responsible for watching only what you have the right to. Product names, logos and the console wordmarks belong to their owners.

This product uses TMDB and the TMDB APIs but is not endorsed, certified, or otherwise approved by TMDB. Where-to-watch data is provided by [JustWatch](https://www.justwatch.com).

## Licence

Copyright (C) 2026 hiitsgabe and the Ilona TV contributors. Ilona TV is free software under the [GNU General Public License v3.0](LICENSE) (`GPL-3.0-only`). The bundled Inter font is under the SIL Open Font License.
