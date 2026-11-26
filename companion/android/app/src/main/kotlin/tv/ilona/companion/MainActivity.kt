package tv.ilona.companion

import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var nsd: Nsd? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "tv.ilona.companion/host")
        val finder = Nsd(this, channel).also { nsd = it }
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "discoverStart" -> { finder.start(); result.success(null) }
                "discoverStop" -> { finder.stop(); result.success(null) }
                "deviceName" -> result.success(Build.MODEL)
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        nsd?.stop()
        super.onDestroy()
    }
}
