package tv.ilona.app

import android.Manifest
import android.accessibilityservice.AccessibilityService
import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.drawable.Drawable
import android.media.AudioManager
import android.media.MediaScannerConnection
import android.media.tv.TvInputInfo
import android.media.tv.TvInputManager
import android.net.Uri
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Build
import android.os.Debug
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.provider.Settings
import android.util.Log
import android.view.KeyEvent
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.text.Collator
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread

internal const val TAG = "IlonaTV"

/** Android side of the `tv.ilona/host` channel. A missing package answers false/null, never a channel error. */
object HostChannel {
    private const val CHANNEL = "tv.ilona/host"
    private const val ICON_MAX_WIDTH = 320
    private const val SEARCH_TIMEOUT_MS = 10_000L
    const val IMAGES_REQUEST = 8
    // READ_EXTERNAL_STORAGE has no effect from API 33, where reading other apps' pictures takes READ_MEDIA_IMAGES.
    private val IMAGES_PERMISSION =
        if (Build.VERSION.SDK_INT >= 33) Manifest.permission.READ_MEDIA_IMAGES else Manifest.permission.READ_EXTERNAL_STORAGE
    // What both BitmapFactory and Flutter decode.
    private val IMAGE_TYPES = arrayOf("image/jpeg", "image/png", "image/webp", "image/gif", "image/bmp")
    private val IMAGE_EXTENSIONS = setOf("jpg", "jpeg", "png", "webp", "gif", "bmp")

    /** The `images` call waiting on the permission dialog (MainActivity.onRequestPermissionsResult). */
    private var pendingImages: MethodChannel.Result? = null

    /** The running engine's messenger, for calls INTO Dart from the service (the assistant); null without one. */
    @Volatile private var messenger: BinaryMessenger? = null
    private val main = Handler(Looper.getMainLooper())

    fun unregister() { messenger = null }

    val hasEngine get() = messenger != null

    /**
     * Asks the Dart side (Host.onAssistantSearch) for the assistant's hits of [type] ("youtube"), on the main thread,
     * [done] on it too: the hits, or null when there is no engine to ask (Ilona TV's activity was destroyed) or no
     * answer within [SEARCH_TIMEOUT_MS].
     */
    fun assistantSearch(type: String, query: String, what: String, done: (List<SearchHit>?) -> Unit) {
        val m = messenger ?: return done(null)
        var answered = false
        val finish = { hits: List<SearchHit>? -> if (!answered) { answered = true; done(hits) } }
        main.post {
            MethodChannel(m, CHANNEL).invokeMethod(
                "assistantSearch", mapOf("type" to type, "query" to query, "what" to what),
                object : MethodChannel.Result {
                    override fun success(result: Any?) = finish((result as? List<*>).orEmpty().mapNotNull { hit ->
                        val h = hit as? Map<*, *> ?: return@mapNotNull null
                        SearchHit(
                            title = h["title"] as? String ?: return@mapNotNull null,
                            sub = h["sub"] as? String ?: "",
                            posterUrl = h["poster"] as? String,
                            uri = h["uri"] as? String,
                            webUri = h["webUri"] as? String,
                            pkg = h["package"] as? String,
                            id = h["id"] as? String,
                            today = h["today"] as? Boolean ?: false,
                            homeLogo = h["homeLogo"] as? String,
                            awayLogo = h["awayLogo"] as? String,
                            homeAbbr = h["homeAbbr"] as? String ?: "",
                            awayAbbr = h["awayAbbr"] as? String ?: "",
                        )
                    })
                    override fun error(code: String, msg: String?, details: Any?) {
                        Log.w(TAG, "assistantSearch $code: $msg"); finish(null)
                    }
                    override fun notImplemented() = finish(null)
                })
            main.postDelayed({ if (!answered) Log.w(TAG, "assistantSearch: no answer"); finish(null) }, SEARCH_TIMEOUT_MS)
        }
    }

    /** Opens [hit] where it lives: its own uri (then the web one) in its package. */
    fun open(ctx: Context, hit: SearchHit): Boolean = open(ctx, hit.uri, hit.pkg) || open(ctx, hit.webUri, hit.pkg)

    /**
     * Has the Dart side open the hit [id] of [type] the way the home does (Host.onAssistantOpen): "games" with a
     * game's id, "movie" or "series" with a TMDB id.
     */
    fun assistantOpen(type: String, id: String) {
        val m = messenger ?: return Unit.also { Log.w(TAG, "assistantOpen: no engine") }
        main.post {
            MethodChannel(m, CHANNEL).invokeMethod("assistantOpen", mapOf("type" to type, "id" to id),
                object : MethodChannel.Result {
                    override fun success(result: Any?) { if (result != true) Log.w(TAG, "assistantOpen: nothing opened $id") }
                    override fun error(code: String, msg: String?, details: Any?) { Log.w(TAG, "assistantOpen $code: $msg") }
                    override fun notImplemented() {}
                })
        }
    }

    fun register(activity: Activity, messenger: BinaryMessenger) {
        this.messenger = messenger
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                // Worker thread: the first call loads every app's label resources and would hold up key dispatch.
                "listApps" -> thread {
                    val apps = runCatching { listApps(activity) }
                    activity.runOnUiThread {
                        apps.onSuccess(result::success).onFailure {
                            Log.w(TAG, "listApps failed", it)
                            result.error("listApps", it.message, null)
                        }
                    }
                }
                // Worker thread, as listApps: the package manager answers over IPC.
                "appsFor" -> {
                    val uri = call.argument<String>("uri")
                    thread {
                        val apps = runCatching { appsFor(activity, uri) }
                        activity.runOnUiThread {
                            apps.onSuccess(result::success).onFailure {
                                Log.w(TAG, "appsFor failed", it)
                                result.error("appsFor", it.message, null)
                            }
                        }
                    }
                }
                // Worker thread too: each banner is decoded and PNG-encoded, and the Apps grid asks for dozens.
                // ponytail: one thread per call; a small shared executor if those bursts ever hurt.
                "appIcon" -> {
                    val pkg = call.argument<String>("package")
                    thread {
                        val png = runCatching { appIcon(activity, pkg) }
                        activity.runOnUiThread {
                            png.onSuccess(result::success).onFailure {
                                Log.w(TAG, "appIcon failed", it)
                                result.error("appIcon", it.message, null)
                            }
                        }
                    }
                }
                // Worker thread, as listApps: each input's labels and state are asked over IPC.
                "tvInputs" -> thread {
                    val inputs = runCatching { tvInputs(activity) }
                    activity.runOnUiThread {
                        inputs.onSuccess(result::success).onFailure {
                            Log.w(TAG, "tvInputs failed", it)
                            result.error("tvInputs", it.message, null)
                        }
                    }
                }
                "openInput" -> result.success(
                    call.argument<String>("id")?.let {
                        start(
                            activity,
                            Intent(activity, InputActivity::class.java)
                                .putExtra(InputActivity.EXTRA_ID, it)
                                .putExtra(InputActivity.EXTRA_NO_SIGNAL, call.argument<String>("noSignal")),
                        )
                    } ?: false
                )
                "launch" -> result.success(
                    call.argument<String>("package")?.let { HomeWatcher.launch(activity, it) } ?: false
                )
                "openStremioAndPlay" -> result.success(
                    call.argument<String>("uri")?.let {
                        HomeWatcher.openStremioAndPlay(activity, it, call.argument<String>("package") ?: HomeWatcher.STREMIO)
                    } ?: false
                )
                "open" -> result.success(
                    open(activity, call.argument<String>("uri"), call.argument<String>("package"))
                )
                "launcherSetup" -> result.success(
                    mapOf(
                        "fireTv" to LauncherSetup.isFireTv(),
                        "serviceOn" to LauncherSetup.serviceEnabled(activity),
                        "sdk" to Build.VERSION.SDK_INT,
                    )
                )
                "setServiceEnabled" -> result.success(
                    LauncherSetup.setServiceEnabled(activity, call.argument<Boolean>("on") == true)
                )
                "openAccessibilitySettings" -> {
                    start(activity, Intent(Settings.ACTION_ACCESSIBILITY_SETTINGS))
                    result.success(null)
                }
                "openAppInfo" -> {
                    val app = Uri.parse("package:${activity.packageName}")
                    start(activity, Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, app))
                    result.success(null)
                }
                // A settings page by component (Fire OS's own pages), else by action. `pause` keeps Launcher mode from
                // taking the Amazon home's settings tab for a Home.
                "openSystemSettings" -> {
                    val component = call.argument<String>("component")
                    val intent = if (component != null) {
                        Intent().setComponent(ComponentName.unflattenFromString(component))
                    } else {
                        Intent(call.argument<String>("action") ?: Settings.ACTION_SETTINGS)
                    }
                    val opened = start(activity, intent)
                    // Only once it opened: a failed start leaves Ilona TV up and nothing would clear the flag.
                    if (opened && call.argument<Boolean>("pause") == true) HomeWatcher.pausedForSettings = true
                    result.success(opened)
                }
                "injectKey" -> {
                    val code = KEYS[call.argument<String>("key")]
                    val target = MainActivity.resumed()
                    if (code == null || target == null) {
                        result.success(false)
                    } else {
                        main.post {
                            target.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, code))
                            target.dispatchKeyEvent(KeyEvent(KeyEvent.ACTION_UP, code))
                        }
                        result.success(true)
                    }
                }
                "globalKey" -> {
                    val action = GLOBAL_ACTIONS[call.argument<String>("key")]
                    result.success(action != null && HomeWatcher.instance?.performGlobalAction(action) == true)
                }
                "audioKey" -> result.success(audioKey(activity, call.argument<String>("key")))
                "keyAccess" -> result.success(
                    mapOf("api" to Build.VERSION.SDK_INT, "service" to (HomeWatcher.instance != null)),
                )
                "advertise" -> {
                    advertise(activity, call.argument<Int>("port") ?: 0, call.argument<String>("name") ?: "Ilona TV")
                    result.success(null)
                }
                "unadvertise" -> {
                    unadvertise(activity)
                    result.success(null)
                }
                "processMemoryKb" -> result.success(processMemoryKb())
                "deviceMemoryKb" -> result.success(ActivityManager.MemoryInfo().also {
                    (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(it)
                }.totalMem / 1024)
                // Settings > Processes: the activity manager's records (each process's last measured memory and
                // its rank) and the device's memory. The dump needs DUMP, granted over adb; without it the text is
                // dumpsys's refusal, which Dart reads as none. The meminfo service itself is closed to apps.
                "processes" -> thread {
                    val dump = runCatching {
                        val p = ProcessBuilder("dumpsys", "activity", "processes").redirectErrorStream(true).start()
                        p.inputStream.bufferedReader().use { it.readText() }.also { p.waitFor() }
                    }
                    val mem = ActivityManager.MemoryInfo()
                    (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager).getMemoryInfo(mem)
                    activity.runOnUiThread {
                        dump.onSuccess {
                            result.success(mapOf("dump" to it, "availKb" to mem.availMem / 1024, "totalKb" to mem.totalMem / 1024))
                        }.onFailure { result.error("processes", it.message, null) }
                    }
                }
                // What the system lets any app close: the package's processes that are in the background.
                "killBackground" -> {
                    val pkg = call.argument<String>("package")
                    if (pkg != null) (activity.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager)
                        .killBackgroundProcesses(pkg)
                    result.success(pkg != null)
                }
                "keepRunning" -> result.success(HomeWatcher.keepRunning(activity).toList())
                // The rest (a VPN, a player's service): Force stop on the app's page, clicked by the service. False
                // without the service or when the page does not open.
                "forceStop" -> result.success(
                    call.argument<String>("package")?.let { HomeWatcher.forceStop(activity, it) } ?: false,
                )
                "filesDir" -> result.success(activity.filesDir.absolutePath)
                // Asked only here, when the tile editor's picker opens.
                "images" -> {
                    pendingImages?.success(null)
                    pendingImages = result
                    if (activity.checkSelfPermission(IMAGES_PERMISSION) == PackageManager.PERMISSION_GRANTED) {
                        imagesPermitted(activity, true)
                    } else {
                        activity.requestPermissions(arrayOf(IMAGES_PERMISSION), IMAGES_REQUEST)
                    }
                }
                "imageThumb" -> worker(activity, result, "imageThumb") {
                    picture(activity, call.argument<String>("uri"), 320, 192)?.encoded()
                }
                // A copy of its own, so the tile survives the original being moved or deleted; scaled down, so a
                // photo does not cost the home a full-size decode on every start.
                "copyImage" -> worker(activity, result, "copyImage") {
                    picture(activity, call.argument<String>("uri"), 640, 384)?.encoded()?.let { bytes ->
                        val dir = File(activity.filesDir, "tiles").apply { mkdirs() }
                        File(dir, "${System.currentTimeMillis()}.img").apply { writeBytes(bytes) }.absolutePath
                    }
                }
                // Raw RGBA pixels, copied into a bitmap here on the main thread (a millisecond or two), where the
                // curtain draws it. Pixels that do not fit their size keep the last snapshot.
                "setSnapshot" -> {
                    val rgba = call.argument<ByteArray>("rgba") ?: ByteArray(0)
                    val width = call.argument<Int>("width") ?: 0
                    val height = call.argument<Int>("height") ?: 0
                    runCatching {
                        check(width > 0 && height > 0 && rgba.size == width * height * 4) { "not ${width}x$height pixels" }
                        Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            .also { it.copyPixelsFromBuffer(ByteBuffer.wrap(rgba)) }
                    }.onSuccess {
                        Curtain.snapshot = it
                        result.success(null)
                    }.onFailure {
                        Log.w(TAG, "setSnapshot failed", it)
                        result.error("setSnapshot", it.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    /** Answers the waiting `images` call: the pictures' URIs when [granted], else null. */
    fun imagesPermitted(activity: Activity, granted: Boolean) {
        val result = pendingImages ?: return
        pendingImages = null
        if (!granted) return result.success(null)
        worker(activity, result, "images") { images(activity) }
    }

    // [block] on a worker thread, its value (or its failure) back on the main thread.
    private fun worker(activity: Activity, result: MethodChannel.Result, name: String, block: () -> Any?) = thread {
        val value = runCatching(block)
        activity.runOnUiThread {
            value.onSuccess(result::success).onFailure {
                Log.w(TAG, "$name failed", it)
                result.error(name, it.message, null)
            }
        }
    }

    // Content URIs of the pictures in the media store, newest first. Files that adb or a file manager put in
    // Download or Pictures may not be in the store yet, so those are scanned first; a scan of a known file is cheap.
    private fun images(ctx: Context): List<String> {
        scan(ctx, Environment.DIRECTORY_DOWNLOADS, Environment.DIRECTORY_PICTURES)
        val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val selection = "${MediaStore.Images.Media.MIME_TYPE} IN (${IMAGE_TYPES.joinToString { "?" }})"
        return ctx.contentResolver.query(
            collection, arrayOf(MediaStore.Images.Media._ID), selection, IMAGE_TYPES,
            "${MediaStore.Images.Media.DATE_ADDED} DESC",
        )?.use { c ->
            buildList { while (c.moveToNext()) add(ContentUris.withAppendedId(collection, c.getLong(0)).toString()) }
        }.orEmpty()
    }

    // Where the File API may not list the folder (Android 10's scoped storage), nothing is scanned.
    @Suppress("DEPRECATION") // getExternalStoragePublicDirectory: only the folders' paths, nothing is written there
    private fun scan(ctx: Context, vararg folders: String) {
        val paths = folders.flatMap { folder ->
            Environment.getExternalStoragePublicDirectory(folder).walk().maxDepth(2)
                .filter { it.isFile && it.extension.lowercase() in IMAGE_EXTENSIONS }.map { it.path }.toList()
        }.take(500)
        if (paths.isEmpty()) return
        val done = CountDownLatch(paths.size)
        MediaScannerConnection.scanFile(ctx, paths.toTypedArray(), null) { _, _ -> done.countDown() }
        done.await(5, TimeUnit.SECONDS)
    }

    // The picture at [uri], upright and scaled down to the smallest size that still covers [w] x [h] (never up). It
    // decodes at the largest power-of-two reduction that keeps it covering, so a photo never decodes at full size.
    private fun picture(ctx: Context, uri: String?, w: Int, h: Int): Bitmap? {
        val u = Uri.parse(uri ?: return null)
        val cr = ctx.contentResolver
        val degrees = runCatching {
            // MediaColumns.ORIENTATION from API 29, ImageColumns' before: the same column.
            cr.query(u, arrayOf("orientation"), null, null, null)
                ?.use { if (it.moveToFirst()) it.getInt(0) else 0 }
        }.getOrNull() ?: 0
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        (cr.openInputStream(u) ?: return null).use { BitmapFactory.decodeStream(it, null, bounds) }
        val sideways = degrees % 180 != 0
        val width = if (sideways) bounds.outHeight else bounds.outWidth
        val height = if (sideways) bounds.outWidth else bounds.outHeight
        if (width <= 0 || height <= 0) return null
        var sample = 1
        while (width / (sample * 2) >= w && height / (sample * 2) >= h) sample *= 2
        val decoded = (cr.openInputStream(u) ?: return null).use {
            BitmapFactory.decodeStream(it, null, BitmapFactory.Options().apply { inSampleSize = sample })
        } ?: return null
        val scale = minOf(1f, maxOf(w.toFloat() * sample / width, h.toFloat() * sample / height))
        if (scale == 1f && degrees == 0) return decoded
        val m = Matrix().apply { postScale(scale, scale); postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, m, true)
            .also { if (it !== decoded) decoded.recycle() }
    }

    // PNG when it has transparency, else JPEG; the bitmap is recycled.
    private fun Bitmap.encoded(): ByteArray {
        val out = ByteArrayOutputStream()
        compress(if (hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG, 90, out)
        recycle()
        return out.toByteArray()
    }

    /** Sends Ilona TV back to its home screen (see MainActivity.onNewIntent). Main thread. */
    fun goHome(messenger: BinaryMessenger) = MethodChannel(messenger, CHANNEL).invokeMethod("goHome", null)

    private var inputsCallback: TvInputManager.TvInputCallback? = null

    /** While Ilona TV is in front ([on]), tells Dart (`inputsChanged`) when an input comes, goes or changes state. */
    fun watchInputs(ctx: Context, messenger: BinaryMessenger, on: Boolean) {
        val tim = ctx.getSystemService(Context.TV_INPUT_SERVICE) as? TvInputManager ?: return
        inputsCallback?.let { tim.unregisterCallback(it) }
        inputsCallback = null
        if (!on) return
        val changed = { MethodChannel(messenger, CHANNEL).invokeMethod("inputsChanged", null) }
        inputsCallback = object : TvInputManager.TvInputCallback() {
            override fun onInputStateChanged(inputId: String, state: Int) = changed()
            override fun onInputAdded(inputId: String) = changed()
            override fun onInputRemoved(inputId: String) = changed()
        }.also { tim.registerCallback(it, Handler(Looper.getMainLooper())) }
    }

    // Every TV input, as raw fields; Dart's visibleInputs picks the cards. The state is null when the device will
    // not tell, the label the user's name for it on Fire OS (else the system's), the device its HDMI-CEC name. An
    // input that fails to read is left out. None without a TV input service (the emulator, Google TV).
    private fun tvInputs(ctx: Context): List<Map<String, Any?>> {
        val tim = ctx.getSystemService(Context.TV_INPUT_SERVICE) as? TvInputManager ?: return emptyList()
        return tim.tvInputList.mapNotNull { info ->
            runCatching {
                val system = info.loadLabel(ctx).toString()
                mapOf(
                    "id" to info.id,
                    "type" to info.type,
                    "parent" to info.parentId,
                    "hidden" to info.isHidden(ctx),
                    "state" to runCatching { tim.getInputState(info.id) }.getOrNull(),
                    "label" to (info.loadCustomLabel(ctx)?.toString()?.takeIf { it.isNotBlank() } ?: system),
                    "systemLabel" to system,
                    "device" to cecName(info),
                )
            }.onFailure { Log.w(TAG, "tv input ${info.id}", it) }.getOrNull()
        }
    }

    // HDMI-CEC's name for the device behind [info]. getHdmiDeviceInfo is a system API, hence the reflection;
    // null when there is no device or the call is refused.
    private fun cecName(info: TvInputInfo): String? = runCatching {
        val device = TvInputInfo::class.java.getMethod("getHdmiDeviceInfo").invoke(info) ?: return null
        device.javaClass.getMethod("getDisplayName").invoke(device) as? String
    }.getOrNull()?.takeIf { it.isNotBlank() }

    // Apps with a TV or a phone launcher activity, minus Ilona TV, by label. TV activity first, so its label wins.
    // Each says whether it has a TV activity and whether it is a system app (an updated one counts as the
    // user's); Dart's offeredApps picks what to show.
    @Suppress("DEPRECATION") // the ResolveInfoFlags overload needs API 33, minSdk is 28
    private fun listApps(ctx: Context): List<Map<String, Any>> {
        val pm = ctx.packageManager
        fun query(category: String) = pm.queryIntentActivities(Intent(Intent.ACTION_MAIN).addCategory(category), 0)
        val tv = query(Intent.CATEGORY_LEANBACK_LAUNCHER).map { it to true }
        val phone = query(Intent.CATEGORY_LAUNCHER).map { it to false }
        return (tv + phone)
            .filter { it.first.activityInfo.packageName != ctx.packageName }
            .distinctBy { it.first.activityInfo.packageName }
            .map { (info, isTv) ->
                val flags = info.activityInfo.applicationInfo.flags
                mapOf(
                    "package" to info.activityInfo.packageName,
                    "label" to info.loadLabel(pm).toString(),
                    "tv" to isTv,
                    // An updated system app is still a system app: user installs never carry FLAG_SYSTEM.
                    "system" to ((flags and ApplicationInfo.FLAG_SYSTEM) != 0),
                )
            }
            .sortedWith(compareBy(Collator.getInstance()) { it.getValue("label") as String })
    }

    // Packages with an activity that views [uri], minus Ilona TV.
    @Suppress("DEPRECATION") // as in listApps
    private fun appsFor(ctx: Context, uri: String?): List<String> {
        if (uri == null) return emptyList()
        return ctx.packageManager
            .queryIntentActivities(Intent(Intent.ACTION_VIEW, Uri.parse(uri)), PackageManager.MATCH_ALL)
            .map { it.activityInfo.packageName }
            .filter { it != ctx.packageName }
            .distinct()
    }

    // PNG of the launch activity's banner (falls back to the app's banner), else its icon, at most 320 px wide.
    private fun appIcon(ctx: Context, pkg: String?): ByteArray? {
        val pm = ctx.packageManager
        val info = pkg?.let { launchIntent(ctx, it) }?.resolveActivityInfo(pm, 0) ?: return null
        return (info.loadBanner(pm) ?: info.loadIcon(pm)).toPng(ICON_MAX_WIDTH)
    }

    private fun Drawable.toPng(maxWidth: Int): ByteArray {
        val w = intrinsicWidth.takeIf { it > 0 } ?: maxWidth
        val h = intrinsicHeight.takeIf { it > 0 } ?: maxWidth
        val bw = minOf(w, maxWidth)
        val bitmap = Bitmap.createBitmap(bw, maxOf(1, h * bw / w), Bitmap.Config.ARGB_8888)
        setBounds(0, 0, bitmap.width, bitmap.height)
        draw(Canvas(bitmap))
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    private fun open(ctx: Context, uri: String?, pkg: String?): Boolean {
        if (uri == null) return false
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(uri))
        if (pkg != null) intent.setPackage(pkg)
        return start(ctx, intent)
    }

    private val KEYS = mapOf(
        "up" to KeyEvent.KEYCODE_DPAD_UP,
        "down" to KeyEvent.KEYCODE_DPAD_DOWN,
        "left" to KeyEvent.KEYCODE_DPAD_LEFT,
        "right" to KeyEvent.KEYCODE_DPAD_RIGHT,
        "ok" to KeyEvent.KEYCODE_DPAD_CENTER,
        "back" to KeyEvent.KEYCODE_BACK,
    )

    // The D-pad's global actions are API 33's; Back and Home date from API 16.
    private val GLOBAL_ACTIONS = buildMap {
        put("back", AccessibilityService.GLOBAL_ACTION_BACK)
        put("home", AccessibilityService.GLOBAL_ACTION_HOME)
        if (Build.VERSION.SDK_INT >= 33) {
            put("up", AccessibilityService.GLOBAL_ACTION_DPAD_UP)
            put("down", AccessibilityService.GLOBAL_ACTION_DPAD_DOWN)
            put("left", AccessibilityService.GLOBAL_ACTION_DPAD_LEFT)
            put("right", AccessibilityService.GLOBAL_ACTION_DPAD_RIGHT)
            put("ok", AccessibilityService.GLOBAL_ACTION_DPAD_CENTER)
        }
    }

    private fun audioKey(ctx: Context, key: String?): Boolean {
        val audio = ctx.getSystemService(AudioManager::class.java) ?: return false
        // A volume change can be refused (Do Not Disturb throws SecurityException).
        return runCatching {
            when (key) {
                "volumeUp", "volumeDown" -> audio.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    if (key == "volumeUp") AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                    AudioManager.FLAG_SHOW_UI,
                )
                "mute" -> audio.adjustStreamVolume(
                    AudioManager.STREAM_MUSIC,
                    AudioManager.ADJUST_TOGGLE_MUTE,
                    AudioManager.FLAG_SHOW_UI,
                )
                "playPause" -> for (a in intArrayOf(KeyEvent.ACTION_DOWN, KeyEvent.ACTION_UP)) {
                    audio.dispatchMediaKeyEvent(KeyEvent(a, KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE))
                }
                else -> return false
            }
            true
        }.getOrDefault(false)
    }

    private var registration: NsdManager.RegistrationListener? = null

    private fun advertise(ctx: Context, port: Int, name: String) {
        unadvertise(ctx)
        val info = NsdServiceInfo().apply {
            serviceName = "$name on ${Build.MODEL}"
            serviceType = "_ilonatv._tcp"
            setPort(port)
            setAttribute("v", "1")
            setAttribute("model", Build.MODEL)
        }
        val listener = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(info: NsdServiceInfo) { Log.i(TAG, "advertising ${info.serviceName}") }
            override fun onRegistrationFailed(info: NsdServiceInfo, code: Int) {
                Log.w(TAG, "advertise failed: $code")
                if (registration === this) registration = null
            }
            override fun onServiceUnregistered(info: NsdServiceInfo) {}
            override fun onUnregistrationFailed(info: NsdServiceInfo, code: Int) {}
        }
        registration = listener
        runCatching {
            nsd(ctx).registerService(info, NsdManager.PROTOCOL_DNS_SD, listener)
        }.onFailure {
            Log.w(TAG, "advertise failed", it)
            registration = null
        }
    }

    private fun unadvertise(ctx: Context) {
        val l = registration ?: return
        registration = null
        runCatching { nsd(ctx).unregisterService(l) }
    }

    private fun nsd(ctx: Context) = ctx.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager

    private fun processMemoryKb(): Int = Debug.MemoryInfo().also { Debug.getMemoryInfo(it) }.totalPss
}

internal fun launchIntent(ctx: Context, pkg: String): Intent? =
    ctx.packageManager.run { getLeanbackLaunchIntentForPackage(pkg) ?: getLaunchIntentForPackage(pkg) }

// Own task, so the target app never lands on top of Ilona TV's (singleTask) stack; the service and the boot receiver,
// not being activities, need it anyway.
internal fun start(ctx: Context, intent: Intent): Boolean = try {
    ctx.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
    true
} catch (e: RuntimeException) { // ActivityNotFoundException, SecurityException
    Log.w(TAG, "startActivity failed: ${e.message}")
    false
}
