package tv.ilona.companion

import android.content.Intent
import android.net.Uri
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nsd: Nsd? = null
    private var adb: Adb? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv.ilona.companion/host")
        val finder = Nsd(this, channel).also { nsd = it }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "discoverStart" -> { finder.start(); result.success(null) }
                "discoverStop" -> { finder.stop(); result.success(null) }
                "deviceName" -> result.success(Build.MODEL)
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

    override fun onDestroy() {
        nsd?.stop()
        adb?.close()
        super.onDestroy()
    }
}
