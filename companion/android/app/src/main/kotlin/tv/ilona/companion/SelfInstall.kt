package tv.ilona.companion

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import io.flutter.plugin.common.MethodChannel
import java.io.File
import kotlin.concurrent.thread

/**
 * About's update: installs a downloaded APK over the companion with a PackageInstaller session, which asks the person
 * to confirm. The session's status comes back here; on success the system replaces the app and kills this
 * process, so only a failure (declined, a bad APK) ever answers the call.
 */
class SelfInstall : BroadcastReceiver() {
    companion object {
        private var pending: MethodChannel.Result? = null

        fun install(activity: Activity, path: String, result: MethodChannel.Result) {
            pending?.success("superseded")
            pending = result
            thread {
                val installer = activity.packageManager.packageInstaller
                var id = -1
                val error = runCatching {
                    val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
                    params.setAppPackageName(activity.packageName)
                    id = installer.createSession(params)
                    installer.openSession(id).use { session ->
                        val apk = File(path)
                        session.openWrite("update.apk", 0, apk.length()).use { out ->
                            apk.inputStream().use { it.copyTo(out) }
                            session.fsync(out)
                        }
                        // Mutable: the installer adds its status and confirm intent to it.
                        val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                            if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                        val status = PendingIntent.getBroadcast(
                            activity, id, Intent(activity, SelfInstall::class.java), flags,
                        )
                        session.commit(status.intentSender)
                    }
                }.exceptionOrNull()
                if (error != null) {
                    if (id != -1) runCatching { installer.abandonSession(id) }
                    activity.runOnUiThread { answer(error.message ?: error.toString()) }
                }
            }
        }

        private fun answer(error: String?) {
            pending?.success(error)
            pending = null
        }
    }

    override fun onReceive(context: Context, intent: Intent) {
        when (val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val confirm = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                val started = confirm != null && runCatching {
                    context.startActivity(confirm.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                }.isSuccess
                if (!started) answer("no installer")
            }
            PackageInstaller.STATUS_SUCCESS -> answer(null)
            else -> answer(intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE) ?: "status $status")
        }
    }
}
