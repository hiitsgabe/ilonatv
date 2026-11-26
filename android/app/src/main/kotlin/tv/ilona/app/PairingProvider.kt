package tv.ilona.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Binder
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.FileNotFoundException

/**
 * What only adb can reach. The manifest guards it with DUMP, which the adb shell holds and ordinary apps cannot; any
 * caller but the shell or root (an app granted DUMP over adb, Ilona TV itself) is turned away.
 *
 * The pairing secret for the companion's installer, read with `content query --uri content://tv.ilona.app.pairing/secret`,
 * which prints `Row: 0 secret=<32 hex>` (`secret=NULL` before Ilona TV's first launch has made one). Pairing with the
 * secret renews it, so each read pairs once.
 *
 * A settings import, written with `content write --uri content://tv.ilona.app.pairing/import < settings.json` to
 * files/import/settings.json, which the next start of Ilona TV reads (settings_import.dart) and deletes. The prefs
 * themselves are left alone: the running app would overwrite them on its next save.
 */
class PairingProvider : ContentProvider() {
    override fun onCreate() = true

    // Process.SHELL_UID and ROOT_UID, which are API 29; minSdk is 28.
    private fun fromAdb() = Binder.getCallingUid().let { it == 2000 || it == 0 }

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val cursor = MatrixCursor(arrayOf("secret"))
        if (!fromAdb()) return cursor
        val secret = context!!.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.companionSecret", null)
        return cursor.apply { addRow(arrayOf(secret)) }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (!fromAdb()) throw SecurityException("adb only")
        if (uri.path != "/import" || !mode.startsWith("w")) throw FileNotFoundException(uri.toString())
        val dir = File(context!!.filesDir, "import").apply { mkdirs() }
        val tmp = File(dir, "settings.json.tmp")
        // The rename waits for the shell to close its end, so a start never reads half a file; a shell that dies
        // mid-copy closes with an error and leaves nothing.
        return ParcelFileDescriptor.open(
            tmp,
            ParcelFileDescriptor.MODE_WRITE_ONLY or ParcelFileDescriptor.MODE_CREATE or ParcelFileDescriptor.MODE_TRUNCATE,
            Handler(Looper.getMainLooper()),
        ) { e -> if (e == null) tmp.renameTo(File(dir, "settings.json")) else tmp.delete() }
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
}
