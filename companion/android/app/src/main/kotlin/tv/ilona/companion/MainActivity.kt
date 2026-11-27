package tv.ilona.companion

import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nsd: Nsd? = null
    private var adb: Adb? = null
    private var host: MethodChannel? = null

    // On while the remote is in front: the rocker drives the TV, not the phone.
    private var volumeKeys = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv.ilona.companion/host")
        host = channel
        val finder = Nsd(this, channel).also { nsd = it }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "discoverStart" -> { finder.start(); result.success(null) }
                "discoverStop" -> { finder.stop(); result.success(null) }
                "deviceName" -> result.success(Build.MODEL)
                "volumeKeys" -> {
                    volumeKeys = call.arguments == true
                    result.success(null)
                }
                "appVersion" -> result.success(packageManager.getPackageInfo(packageName, 0).versionName)
                // About's update.
                "cacheDir" -> result.success(cacheDir.absolutePath)
                "canInstall" -> result.success(packageManager.canRequestPackageInstalls())
                "allowInstalls" -> {
                    runCatching {
                        startActivity(
                            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
                        )
                    }
                    result.success(null)
                }
                "installApk" -> SelfInstall.install(this, call.argument<String>("path")!!, result)
                "openUrl" -> {
                    val uri = (call.arguments as? String)?.let(Uri::parse)
                    result.success(
                        uri?.scheme == "https" &&
                            try {
                                startActivity(Intent(Intent.ACTION_VIEW, uri))
                                true
                            } catch (e: Exception) {
                                false
                            },
                    )
                }
                else -> result.notImplemented()
            }
        }
        val a = Adb(filesDir).also { adb = it }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv.ilona.companion/adb").setMethodCallHandler(a::onCall)
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        val up = when (event.keyCode) {
            KeyEvent.KEYCODE_VOLUME_UP -> true
            KeyEvent.KEYCODE_VOLUME_DOWN -> false
            else -> null
        }
        if (!volumeKeys || up == null) return super.dispatchKeyEvent(event)
        // A held rocker repeats its down; each one is a step on the TV.
        if (event.action == KeyEvent.ACTION_DOWN) host?.invokeMethod("volumeKey", mapOf("up" to up))
        return true
    }

    override fun onDestroy() {
        nsd?.stop()
        adb?.close()
        super.onDestroy()
    }
}
