package tv.ilona.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Launcher mode: opens Ilona TV at boot, when no app-switch lock is in the way. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Intent.ACTION_BOOT_COMPLETED && context.fireTvMode()) {
            LauncherSetup.ensure(context)
            start(context, Intent(context, MainActivity::class.java))
        }
    }
}
