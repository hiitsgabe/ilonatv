package app.elimor.app

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    // Whether Flutter has drawn into the current surface. Per activity: a new one in a warm process starts without.
    private var uiShown = false

    companion object {
        private const val MIC_REQUEST = 7
        /** Asked once per process: a person who said no is not nagged on every resume. */
        private var micAsked = false
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        LauncherSetup.ensure(this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        HostChannel.register(this, flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun onResume() {
        super.onResume()
        HomeWatcher.cancelClick()
        HomeWatcher.pausedForSettings = false
        // A surface that survived the pause brings no new first frame.
        if (uiShown) Curtain.hide("resumed")
        flutterEngine?.let { HostChannel.watchInputs(this, it.dartExecutor.binaryMessenger, true) }
        askMic()
    }

    /** The assistant listens on the TV's mic; Fire OS has revoked the grant after a reboot, so ask while it is off. */
    private fun askMic() {
        if (micAsked || !alexaBounce()) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return
        micAsked = true
        Log.i(TAG, "asking for RECORD_AUDIO")
        requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        // No result (an interrupted request) reads as a no.
        if (requestCode == HostChannel.IMAGES_REQUEST) {
            HostChannel.imagesPermitted(this, grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
        }
    }

    override fun onPause() {
        super.onPause()
        flutterEngine?.let { HostChannel.watchInputs(this, it.dartExecutor.binaryMessenger, false) }
    }

    // The engine goes with the activity; the assistant must not call into a dead one.
    override fun onDestroy() {
        HostChannel.unregister()
        super.onDestroy()
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        uiShown = true
        Curtain.hide("drawn")
    }

    override fun onFlutterUiNoLongerDisplayed() {
        super.onFlutterUiNoLongerDisplayed()
        uiShown = false
    }

    // The activity is singleTask, so Home on Google TV and the curtain's relaunch (CLEAR_TOP | SINGLE_TOP) land here.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        Log.i(TAG, "goHome (new intent)")
        flutterEngine?.let { HostChannel.goHome(it.dartExecutor.binaryMessenger) }
    }
}
