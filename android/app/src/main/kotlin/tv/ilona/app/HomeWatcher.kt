package tv.ilona.app

import android.accessibilityservice.AccessibilityService
import android.app.ActivityManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo

/**
 * Launcher mode. Home always opens the Amazon home, and for 5 s after it Android holds back activity starts from
 * background apps. So on Home this raises the [Curtain] and clicks IlonaTv's tile on the Amazon home, which is not held
 * back, with a startActivity queued behind the lock in case the tile is missing. Inert while [fireTvMode] is off.
 */
class HomeWatcher : AccessibilityService() {
    companion object {
        @Volatile
        var instance: HomeWatcher? = null

        /** Uptime of the Home that last raised the curtain. */
        @Volatile
        var lastHomePressed = 0L

        fun sinceHome() = SystemClock.uptimeMillis() - lastHomePressed

        /**
         * Set while Fire OS's own settings are open from IlonaTv: that grid is a tab of the Amazon home, so its window
         * is not a Home. Only a Home press (the broadcast) or IlonaTv coming back clears it.
         */
        @Volatile
        var pausedForSettings = false

        val HOME_PACKAGES = setOf(
            "com.amazon.tv.launcher",
            "com.amazon.firehomestarter",
            "com.google.android.apps.tv.launcherx",
        )
        const val HOME_PRESSED_ACTION = "com.amazon.tv.launcher.HOME_PRESSED"

        /**
         * The Alexa voice UI: when the mic button raises it and [alexaBounce] is on, IlonaTv dismisses it and comes to
         * the front ([onAlexa]). The button's key never reaches an app (Fire OS takes it natively), but its window
         * does, so IlonaTv bounces the window instead. `vizzini` draws the listening/thinking chrome; `aria` the APL
         * response card.
         */
        val ALEXA_PACKAGES = setOf("com.amazon.vizzini", "com.amazon.aria")

        /**
         * Only to drop the duplicate window event Android fires for one window. While the button is held Alexa keeps
         * redrawing (listen, think); each redraw is bounced so IlonaTv keeps the front until the button is released.
         */
        const val ALEXA_BOUNCE_MS = 500L

        /** A bounce this long after the last one is a real new press (ask again), not a held or echoed one. */
        const val NEW_PRESS_GAP = 1500L

        /** Interval between Backs sent at Alexa's results page while it is still on screen (see closeDirective). */
        const val DIRECTIVE_BACK_MS = 400L

        /** Events closer than this are one Home press; a later window event keeps the base while the curtain is up. */
        const val MERGE_MS = 300L

        /**
         * After a tile click that took, the home's window events this soon are the switch to IlonaTv under way, not
         * a new Home: clicking again would bounce between the two apps (and click) until IlonaTv wins.
         */
        const val CLICK_SETTLE_MS = 1500L

        /** A wake this soon after a sleep is the second half of one press on a remote that sends power twice. */
        const val DOUBLE_POWER_MS = 1500L

        /**
         * Starts [pkg]'s launcher activity; false if it has none. A plain start: this only runs with IlonaTv in front,
         * so the active window is IlonaTv's own and there is no Amazon tile to click.
         */
        fun launch(ctx: Context, pkg: String): Boolean = launchIntent(ctx, pkg)?.let { start(ctx, it) } ?: false

        const val STREMIO = "com.stremio.one"

        /**
         * Opens [uri] (a title's, an episode's or a channel's page) in the Stremio app [pkg] and, with the service
         * on, taps its first stream ([playFirstStream]); only in [STREMIO], whose view ids the tap knows. False if
         * the app did not open.
         */
        fun openStremioAndPlay(ctx: Context, uri: String, pkg: String): Boolean {
            if (!start(ctx, Intent(Intent.ACTION_VIEW, Uri.parse(uri)).setPackage(pkg))) return false
            if (pkg == STREMIO) instance?.playFirstStream()
            return true
        }

        /**
         * The packages Force stop must never touch: one whose accessibility service is on (Android drops it from the
         * enabled list on a force stop, and Fire OS has no screen to turn it back on) and the keyboard.
         */
        fun keepRunning(ctx: Context): Set<String> {
            val r = ctx.contentResolver
            val services = android.provider.Settings.Secure.getString(r, "enabled_accessibility_services").orEmpty()
            val ime = android.provider.Settings.Secure.getString(r, "default_input_method").orEmpty()
            return (services.split(':') + ime).mapNotNull { it.substringBefore('/').takeIf(String::isNotEmpty) }.toSet()
        }

        /**
         * Opens [pkg]'s page in Fire OS's settings and has the service click Force stop, then OK, then brings IlonaTv
         * back ([stopApp]). False without the service, for a package [keepRunning] protects, or when the page does
         * not open.
         */
        fun forceStop(ctx: Context, pkg: String): Boolean {
            val service = instance ?: return false
            if (pkg in keepRunning(ctx)) return false
            // A fresh task: Fire OS reuses an app page that is already open and keeps showing the app it was for.
            val page = Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$pkg"))
                .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TASK)
            val settings = page.resolveActivity(ctx.packageManager)?.packageName ?: "com.amazon.tv.settings.v2"
            val label = runCatching {
                ctx.packageManager.run { getApplicationLabel(getApplicationInfo(pkg, 0)).toString() }
            }.getOrNull()
            if (!start(ctx, page)) return false
            // Fire OS's settings are a tab of the Amazon home: not a Home while the click runs.
            pausedForSettings = true
            service.stopApp(pkg, settings, label)
            return true
        }

        /** IlonaTv is back (MainActivity.onResume): drops a click chain still looking for a tile. */
        fun cancelClick() {
            instance?.handler?.removeCallbacksAndMessages(null)
        }
    }

    private val handler = Handler(Looper.getMainLooper())

    /** Uptime of the last tile click that took; see [CLICK_SETTLE_MS]. */
    private var clickedAt = 0L

    /**
     * While the curtain is up, the D-pad and OK would land on the Amazon home under it (moving its focus, with a click
     * each): they are dropped until IlonaTv is back. Home, power, volume and media keys pass.
     */
    override fun onKeyEvent(event: KeyEvent): Boolean {
        // While the assistant overlay is up, Back closes it (and does not reach the app behind).
        if (Assistant.isUp && event.keyCode == KeyEvent.KEYCODE_BACK) {
            if (event.action == KeyEvent.ACTION_UP) Assistant.hide("back")
            return true
        }
        // With search results up, the D-pad moves between them and OK opens the one chosen; the app behind stays put.
        if (Assistant.hasResults) {
            val down = event.action == KeyEvent.ACTION_DOWN
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_LEFT -> { if (down) Assistant.moveResults(-1); return true }
                KeyEvent.KEYCODE_DPAD_RIGHT -> { if (down) Assistant.moveResults(1); return true }
                KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER ->
                    { if (down) Assistant.playSelected(this); return true }
            }
        }
        return Curtain.isUp && event.keyCode in SWALLOWED
    }

    private val SWALLOWED = setOf(
        KeyEvent.KEYCODE_DPAD_UP, KeyEvent.KEYCODE_DPAD_DOWN, KeyEvent.KEYCODE_DPAD_LEFT,
        KeyEvent.KEYCODE_DPAD_RIGHT, KeyEvent.KEYCODE_DPAD_CENTER, KeyEvent.KEYCODE_ENTER, KeyEvent.KEYCODE_BACK,
        KeyEvent.KEYCODE_MENU,
    )

    /** The double power re-sleep: apart from [handler], which IlonaTv's return clears to drop a pending tile click. */
    private val powerHandler = Handler(Looper.getMainLooper())

    private val homePressed = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            pausedForSettings = false
            onHome("broadcast")
        }
    }

    /** Real time (counting deep sleep) of the last screen-off this service did not cause; 0 once matched. */
    private var screenOffAt = 0L

    /** The next screen-off is the one this service asked for: it must not arm the fix again. */
    private var ownSleep = false

    // Some remotes send power over IR and Bluetooth at once, so one press toggles twice a second apart. Off then on
    // is undone here by sleeping again. On then off cannot be: Fire OS suspends to RAM at once and no app can keep
    // the CPU up, so the wake must come from another key (any key but power wakes the TV). Real time, not uptime:
    // uptime stops in suspend, and a broadcast delivered on resume would look closer than it was.
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val now = SystemClock.elapsedRealtime()
            when (intent.action) {
                Intent.ACTION_SCREEN_OFF -> {
                    screenOffAt = if (ownSleep) 0L else now
                    ownSleep = false
                }
                Intent.ACTION_SCREEN_ON -> {
                    val sinceOff = now - screenOffAt
                    if (screenOffAt != 0L && sinceOff < DOUBLE_POWER_MS && fireTvMode() && doublePowerFix()) {
                        Log.w(TAG, "double power: woke ${sinceOff}ms after sleeping, sleeping again")
                        powerHandler.postDelayed({
                            ownSleep = performGlobalAction(GLOBAL_ACTION_LOCK_SCREEN)
                        }, 300)
                    }
                    screenOffAt = 0L
                }
            }
        }
    }

    /** A debug build (AGP 8 generates no BuildConfig unless asked). */
    private val debuggable get() = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0

    override fun onServiceConnected() {
        // Exported: the Amazon home sends it. The flag is required from API 34 and ignored before API 33.
        registerReceiver(homePressed, IntentFilter(HOME_PRESSED_ACTION), Context.RECEIVER_EXPORTED)
        registerReceiver(screen, IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON) })
        // Debug builds only: the assistant overlay with canned results, for screenshots on the emulator.
        if (debuggable) registerReceiver(AssistantPreview, IntentFilter(AssistantPreview.ACTION), Context.RECEIVER_EXPORTED)
        Log.i(TAG, "service connected (debug preview: $debuggable)")
        instance = this
    }

    // Only window-state changes are subscribed (res/xml/accessibility.xml): a home window coming up is a Home the
    // broadcast may have missed.
    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        val pkg = event.packageName?.toString()
        if (pkg in ALEXA_PACKAGES && fireTvMode() && alexaBounce()) {
            onAlexa(pkg, event.className?.toString())
            return
        }
        if (pkg !in HOME_PACKAGES) return
        // Alexa also acts on what she heard: a search or play request opens her results page on Amazon's launcher
        // (deeplink.activity.Directive…). With the assistant up that page is hers, not a Home press: Back closes it
        // and the app underneath stays where it was.
        if (Assistant.isUp && event.className?.toString()?.contains("Directive") == true) {
            closeDirective(0)
            return
        }
        if (pausedForSettings) {
            Log.i(TAG, "home window ignored: system settings open")
            return
        }
        onHome("window")
    }

    /** Uptime of the last Alexa bounce; [ALEXA_BOUNCE_MS] of quiet after it is one voice session's many windows. */
    private var lastAlexaBounce = 0L

    /**
     * The mic button opened Alexa: cancel its visible chrome with Back and raise IlonaTv's assistant overlay over
     * whatever is in front (the accessibility overlay sits above Alexa too). The app behind keeps playing. While the
     * button is held Alexa redraws and this runs again, each time extending the overlay; releasing lets it hide.
     */
    private fun onAlexa(pkg: String?, className: String?) {
        val now = SystemClock.uptimeMillis()
        val gap = now - lastAlexaBounce
        val repeat = gap < ALEXA_BOUNCE_MS && Assistant.isUp
        // A real new press comes after a gap; the many bounces of one session (held, or Alexa re-showing) come close
        // together. Only a fresh press starts a new question, so an echo does not wipe the answer on screen.
        val fresh = gap > NEW_PRESS_GAP
        lastAlexaBounce = now
        if (!repeat) Log.i(TAG, "alexa bounce: $pkg $className")
        // Cancel Alexa's session the way Home does (a non-protected broadcast): she stops listening and answering, so
        // she does not talk over IlonaTv, the audio focus frees for IlonaTv's own speech, and she releases the mic. No
        // Back, which inside an app would exit the player.
        sendBroadcast(Intent("amazon.speech.RESET_INTERACTIONS"))
        Assistant.show(this, assistantColor(), fresh)
    }

    /**
     * Alexa's results page keeps drawing for ~1.5 s after its window event, and a Back before it is shown is lost.
     * So: while the assistant is up and a launcher window is the ACTIVE one, Back every [DIRECTIVE_BACK_MS], up to 6
     * times. Active, not merely listed: the closed page lingers in [windows] for a moment, and a Back then would land
     * on the app underneath (it exited a video player once). The launcher is only active during the assistant
     * when it is Alexa's page (Home itself is bounced).
     */
    private fun closeDirective(attempt: Int) {
        handler.postDelayed({
            val up = windows.any { it.isActive && it.root?.packageName?.toString() in HOME_PACKAGES }
            if (Assistant.isUp && up) {
                Log.i(TAG, "alexa directive page: back ($attempt)")
                performGlobalAction(GLOBAL_ACTION_BACK)
                if (attempt < 5) closeDirective(attempt + 1)
            }
        }, DIRECTIVE_BACK_MS)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        // Throws if onServiceConnected never ran: a bind and unbind within milliseconds sends no init.
        runCatching { unregisterReceiver(homePressed) }
        runCatching { unregisterReceiver(screen) }
        if (debuggable) runCatching { unregisterReceiver(AssistantPreview) }
        handler.removeCallbacksAndMessages(null)
        powerHandler.removeCallbacksAndMessages(null)
        stopHandler.removeCallbacksAndMessages(null)
        streamHandler.removeCallbacksAndMessages(null)
        Assistant.hide("destroyed")
        Curtain.hide("destroyed")
        super.onDestroy()
    }

    private fun onHome(source: String) {
        val now = SystemClock.uptimeMillis()
        Log.i(TAG, "home event ($source) +${now - lastHomePressed}ms")
        // While the assistant is up, the Amazon home coming up behind it (Alexa was cancelled) is not a Home: keep
        // the assistant. Only a real Home press (the broadcast) closes it and goes home.
        if (Assistant.isUp) {
            if (source != "broadcast") return
            Assistant.hide("home")
        }
        stopHandler.removeCallbacksAndMessages(null) // left the settings page: no click on what comes next
        streamHandler.removeCallbacksAndMessages(null) // left Stremio: no tap on what comes next
        if (!fireTvMode() || now - lastHomePressed < MERGE_MS) return
        // Curtain already up: the home's window event (it lands up to 1.6 s after the broadcast) or a second Home.
        // The press that raised it keeps its time, the base of every +Nms log, and has queued the start already;
        // only the click restarts, which saves a Home pressed between the click and IlonaTv's return.
        val raised = Curtain.isUp
        if (raised && now - clickedAt < CLICK_SETTLE_MS) {
            Log.i(TAG, "home event ignored: a click is under way")
            return
        }
        if (!raised) lastHomePressed = now
        Curtain.show(this)
        val relaunch = Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
        if (!raised) start(this, relaunch) // held back until the lock lifts, unless the tile click gets there first
        // Posted, so the curtain draws before the click's blocking calls into the home.
        handler.post { clickTile("IlonaTv", 0) }
    }

    // Clicks the tile whose description is [label] on the home in front, every 50 ms for 4 s while that home comes up.
    private fun clickTile(label: String, attempt: Int) {
        handler.removeCallbacksAndMessages(null) // one click at a time: a new one replaces a pending retry
        // ponytail: nodes are left to the GC, not recycle()d (a no-op from API 33).
        val tile = rootInActiveWindow?.takeIf { it.packageName?.toString() in HOME_PACKAGES }
            ?.findAccessibilityNodeInfosByText(label)
            ?.firstOrNull { it.isClickable && it.contentDescription?.toString() == label }
        when {
            tile?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true -> {
                clickedAt = SystemClock.uptimeMillis()
                Log.i(TAG, "click '$label' ok attempt=$attempt +${sinceHome()}ms")
            }
            attempt < 80 -> handler.postDelayed({ clickTile(label, attempt + 1) }, 50)
            else -> Log.i(TAG, "tile '$label' not found")
        }
    }

    /** Stremio's first-stream tap: apart from the other handlers, so IlonaTv's return cannot cut it short. */
    private val streamHandler = Handler(Looper.getMainLooper())

    /**
     * On Stremio's page for a title, every 300 ms for 15 s: once its streams are listed (the cards under the
     * description: clickable, with two texts or more), taps the first one, which plays it. A page that went straight
     * to the player (Stremio's own autoPlay, for a stream played before) has no cards: nothing is tapped. Ends when
     * Stremio, once seen, is no longer in front; Home and the service's end cancel it.
     */
    fun playFirstStream() {
        streamHandler.removeCallbacksAndMessages(null)
        val begun = SystemClock.uptimeMillis()
        var seen = false
        fun texts(n: AccessibilityNodeInfo): Int =
            (if (n.className?.endsWith("TextView") == true && !n.text.isNullOrBlank()) 1 else 0) +
                (0 until n.childCount).sumOf { i -> n.getChild(i)?.let(::texts) ?: 0 }
        fun cards(n: AccessibilityNodeInfo, below: Int, out: MutableList<Pair<android.graphics.Rect, AccessibilityNodeInfo>>) {
            val r = android.graphics.Rect().also(n::getBoundsInScreen)
            if (n.isClickable && n.className?.endsWith("FrameLayout") == true && r.top > below && r.left > 150 &&
                texts(n) >= 2
            ) {
                out += r to n
                return
            }
            for (i in 0 until n.childCount) n.getChild(i)?.let { cards(it, below, out) }
        }
        fun step() {
            try {
                if (SystemClock.uptimeMillis() - begun > 15000) {
                    Log.i(TAG, "stremio: no streams in 15 s")
                    return
                }
                val root = rootInActiveWindow
                val pkg = root?.packageName?.toString()
                if (pkg == STREMIO) {
                    seen = true
                    val description = (
                        root.findAccessibilityNodeInfosByViewId("$STREMIO:id/meta_details_description") +
                            root.findAccessibilityNodeInfosByViewId("$STREMIO:id/meta_details_label")
                        ).firstOrNull()
                    if (description != null) {
                        val below = android.graphics.Rect().also(description::getBoundsInScreen).bottom
                        val found = mutableListOf<Pair<android.graphics.Rect, AccessibilityNodeInfo>>()
                        cards(root, below, found)
                        found.minByOrNull { it.first.left }?.let { (_, card) ->
                            Log.i(TAG, "stremio: play the first of ${found.size} streams, ok=${tap(card)}")
                            return
                        }
                    }
                } else if (seen && pkg != null) {
                    Log.i(TAG, "stremio: left for $pkg, no tap")
                    return
                }
                streamHandler.postDelayed({ step() }, 300)
            } catch (e: RuntimeException) {
                Log.w(TAG, "stremio: first stream failed: $e")
            }
        }
        step()
    }

    /** Force stop and its dialog: apart from the other handlers, so IlonaTv's return cannot cut it short. */
    private val stopHandler = Handler(Looper.getMainLooper())

    /**
     * On the app page [forceStop] opened, every 250 ms for 6 s, acting only on [settings]' window and only once the
     * page's title is [label] (the app's name): clicks Force stop, then brings IlonaTv back. Fire OS stops at once;
     * a confirmation, where there is one, gets its OK first. Force stop greyed out (the app is already stopped)
     * brings IlonaTv back at once. Once the page was seen, IlonaTv in front again (the user pressed Back or Home) ends
     * it with nothing done. Home and the service's end cancel it. Text matches are English and Portuguese.
     */
    fun stopApp(pkg: String, settings: String, label: String?) {
        stopHandler.removeCallbacksAndMessages(null)
        val begun = SystemClock.uptimeMillis()
        var clickedAt = 0L
        var seen = false
        fun texts(root: AccessibilityNodeInfo, vararg words: String) =
            words.flatMap { root.findAccessibilityNodeInfosByText(it) }
                .filter { n -> words.any { n.text?.toString().equals(it, ignoreCase = true) } }
        fun step() {
            try {
                val root = rootInActiveWindow
                val front = root?.packageName?.toString()
                if (front == packageName && seen) {
                    Log.i(TAG, "force stop $pkg: IlonaTv is back")
                    return
                }
                val now = SystemClock.uptimeMillis()
                if (now - begun > 6000) {
                    Log.i(TAG, "force stop $pkg: gave up")
                    if (front == settings) backToIlonaTv()
                    return
                }
                if (root != null && front == settings) {
                    seen = true
                    // The page's own app, not one a reused page still shows.
                    val title = root.findAccessibilityNodeInfosByViewId("$settings:id/left_pane_title")
                        .firstOrNull()?.text?.toString()
                    if (clickedAt == 0L && (label == null || title == null || title == label)) {
                        texts(root, "Force stop", "Forçar parada", "Forçar interrupção").firstOrNull()?.let { node ->
                            val button = clickable(node)
                            if (button == null || !button.isEnabled) {
                                Log.i(TAG, "force stop $pkg: already stopped")
                                return backToIlonaTv()
                            }
                            // A touch: Fire OS's settings list ignores an accessibility click.
                            if (tap(button)) clickedAt = now
                        }
                    } else if (clickedAt != 0L) {
                        val ok = root.findAccessibilityNodeInfosByViewId("android:id/button1").firstOrNull()
                            ?: texts(root, "OK").firstOrNull()
                        if (ok != null && clickable(ok)?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true) {
                            Log.i(TAG, "force stop $pkg: stopped, confirmed")
                            stopHandler.postDelayed({ backToIlonaTv() }, 400)
                            return
                        }
                        if (now - clickedAt > 700) {
                            Log.i(TAG, "force stop $pkg: stopped")
                            return backToIlonaTv()
                        }
                    }
                }
                stopHandler.postDelayed({ step() }, 250)
            } catch (e: RuntimeException) {
                Log.w(TAG, "force stop $pkg failed: $e")
            }
        }
        stopHandler.postDelayed({ step() }, 400)
    }

    /** A tap at the middle of [node] on screen; false when the system refuses the gesture. */
    private fun tap(node: AccessibilityNodeInfo): Boolean {
        val r = android.graphics.Rect().also(node::getBoundsInScreen)
        if (r.isEmpty) return false
        val path = android.graphics.Path().apply { moveTo(r.exactCenterX(), r.exactCenterY()) }
        val gesture = android.accessibilityservice.GestureDescription.Builder()
            .addStroke(android.accessibilityservice.GestureDescription.StrokeDescription(path, 0, 50))
            .build()
        return dispatchGesture(gesture, null, null)
    }

    /**
     * IlonaTv's own task to the front: Back could land on another settings page, under the app's. No new intent, so
     * the Settings screen stays where it was. Back only if IlonaTv has no task.
     */
    private fun backToIlonaTv() {
        val task = (getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).appTasks.firstOrNull {
            it.taskInfo.baseActivity?.className == MainActivity::class.java.name
        }
        if (task != null) task.moveToFront() else performGlobalAction(GLOBAL_ACTION_BACK)
    }

    private fun clickable(node: AccessibilityNodeInfo) =
        generateSequence(node) { it.parent }.firstOrNull { it.isClickable }
}
