# Launcher mode

Off by default. When it is on, the remote's Home button brings IlonaTv back instead of the system home, Home from a row or from Settings puts IlonaTv's home back at its top, and IlonaTv starts by itself at boot.

It works through IlonaTv's accessibility service. On Home, the service covers the screen with a snapshot of IlonaTv (the "curtain") until IlonaTv is in front again. The Launcher mode pane in Settings shows the steps for your device with your TV's address filled in.

Extra options on Fire TV, in the same pane:

- **Remote sends power twice**: for remotes that send power over IR and Bluetooth at once. It undoes an off-then-on; turn the TV on with any other button.
- **Mic button opens IlonaTv**: the voice assistant replaces Alexa (needs a Gemini key).

## Fire TV

The Amazon home cannot be replaced, so it always wins the Home button. On top of that, for 5 seconds after Home, Android holds back activity starts from background apps. Launcher mode gets around both: on Home, the service draws the curtain and clicks IlonaTv's tile on the Amazon home, which that lock does not hold back.

1. Open IlonaTv once, so it shows under "Recently used apps" on the Amazon home (pinning it to the favorites bar works too). Launcher mode clicks that tile.
2. Fire OS has no settings screen for third-party accessibility services, so IlonaTv turns on its own. That needs a permission only adb can grant, once:

   ```sh
   adb -s <tv-ip>:5555 shell pm grant tv.ilona.app android.permission.WRITE_SECURE_SETTINGS
   ```

3. In IlonaTv: Settings > Launcher mode > On, then "Check again". The status line reads "Accessibility service: on".

From then on the switch turns the service on and off by itself. While it is on, IlonaTv puts the service back at boot, and when it starts, if it has left the list (after a Fire OS update, say). `pm revoke` with the same arguments takes the permission back.

<details>
<summary>What the switch does, to check it or undo it by hand</summary>

On is the two `put`s below, where `<list>` is what `get` prints. `put` replaces the whole list, so the other services stay in front of IlonaTv's entry, separated by `:`.

```sh
adb shell settings get secure enabled_accessibility_services
adb shell settings put secure enabled_accessibility_services <list>:tv.ilona.app/.HomeWatcher
adb shell settings put secure accessibility_enabled 1
```

Off puts the list back without IlonaTv's entry. To clear the whole list instead (this drops every accessibility service, not only IlonaTv's):

```sh
adb shell 'settings put secure enabled_accessibility_services ""'
```

</details>

## Google TV and Android TV

Not yet tried on a real Google TV device. Google TV reportedly never offers a default-launcher chooser, so go through these in order and stop at the first that works.

1. **The chooser.** Install IlonaTv and press Home. If the system asks "Complete action using", choose IlonaTv and "Always".
2. **Launcher mode, no adb.** Settings > Launcher mode > On opens the system's accessibility settings; turn IlonaTv on there.

   On Android 13 and later, a sideloaded accessibility service is greyed out until restricted settings are allowed for the app. "Open app info" on the Launcher mode pane leads to "Allow restricted settings", and "Open accessibility settings" leads back. If App info has no such option:

   ```sh
   adb shell appops set tv.ilona.app ACCESS_RESTRICTED_SETTINGS allow
   ```

3. **Disable the stock launcher, over adb.** Home then lands on IlonaTv directly. `setupwraith` has to go too, or it re-enables the launcher.

   ```sh
   adb shell pm disable-user --user 0 com.google.android.apps.tv.launcherx
   adb shell pm disable-user --user 0 com.google.android.tungsten.setupwraith
   ```

   Undo with `adb shell pm enable <package>` for both. A Google update may revert it, and the remote's YouTube button may stop working.

## Known limitations

- After "All settings" on Fire TV, Launcher mode ignores the Amazon home until Home is pressed.
- Without IlonaTv's tile under "Recently used apps" or in the favorites bar, the return waits for the 5-second lock.
- Force-stopping IlonaTv removes its accessibility service from the enabled list. With the Fire TV grant and the switch on, IlonaTv puts it back at its next start; on Google TV without the grant, turn it on again in the system settings.
- Keys pressed while the curtain is up reach the system home underneath.
- On Android 13 and later the switch back can show the system launcher for about 200 ms.
