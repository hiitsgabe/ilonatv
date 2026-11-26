package tv.ilona.app

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Launcher mode's switch enables [HomeWatcher] itself by writing the system's list of enabled accessibility services,
 * which takes WRITE_SECURE_SETTINGS, granted once over adb (`pm grant`). Without it, on Google TV, the user turns the
 * service on in the system's Accessibility settings; Fire OS lists no third-party service there.
 */
object LauncherSetup {
    fun isFireTv(): Boolean = Build.MANUFACTURER.equals("Amazon", ignoreCase = true)

    fun serviceEnabled(ctx: Context): Boolean =
        Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES)
            ?.split(':')?.any { it.startsWith("${ctx.packageName}/") } == true

    fun canWriteSettings(ctx: Context): Boolean =
        ctx.checkSelfPermission(Manifest.permission.WRITE_SECURE_SETTINGS) == PackageManager.PERMISSION_GRANTED

    /** Adds or removes IlonaTv's entry and keeps every other service's. False without the permission. */
    fun setServiceEnabled(ctx: Context, on: Boolean): Boolean = try {
        val cr = ctx.contentResolver
        val others = (Settings.Secure.getString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES) ?: "")
            .split(':')
            .filter { it.isNotEmpty() && !it.startsWith("${ctx.packageName}/") }
        val services = if (on) others + "${ctx.packageName}/.HomeWatcher" else others
        Settings.Secure.putString(cr, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES, services.joinToString(":"))
        if (on) Settings.Secure.putInt(cr, Settings.Secure.ACCESSIBILITY_ENABLED, 1)
        true
    } catch (e: SecurityException) {
        Log.w(TAG, "setServiceEnabled($on) failed: ${e.message}")
        false
    }

    /** At boot and on open: puts the service back if the switch is on and it left the list (a Fire OS update). */
    fun ensure(ctx: Context) {
        if (ctx.fireTvMode() && canWriteSettings(ctx) && !serviceEnabled(ctx)) setServiceEnabled(ctx, true)
    }
}
