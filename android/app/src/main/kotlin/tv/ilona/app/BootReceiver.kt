package tv.ilona.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper

/**
 * Launcher mode: opens Ilona TV at boot, when no app-switch lock is in the way, and after an update replaced it (the
 * install killed the running one, and the installer's Done goes back to the Amazon home).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val opens = intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        if (opens && context.fireTvMode()) {
            LauncherSetup.ensure(context)
            val main = Intent(context, MainActivity::class.java)
            start(context, main)
            // Fire OS 8 may refuse a start this soon after the replace; one more try once it has settled.
            if (intent.action == Intent.ACTION_MY_PACKAGE_REPLACED) {
                val done = goAsync()
                Handler(Looper.getMainLooper()).postDelayed({
                    if (MainActivity.resumed() == null) start(context, main)
                    done.finish()
                }, 2000)
            }
        }
    }
}
