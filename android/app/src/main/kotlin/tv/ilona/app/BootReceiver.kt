package tv.ilona.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * Launcher mode: opens Ilona TV at boot, when no app-switch lock is in the way, and after an update replaced it (the
 * install killed the running one, and the installer's Done goes back to the Amazon home).
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val opens = intent.action == Intent.ACTION_BOOT_COMPLETED || intent.action == Intent.ACTION_MY_PACKAGE_REPLACED
        if (opens && context.fireTvMode()) {
            LauncherSetup.ensure(context)
            start(context, Intent(context, MainActivity::class.java))
        }
    }
}
