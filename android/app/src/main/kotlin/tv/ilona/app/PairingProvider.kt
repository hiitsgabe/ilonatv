package tv.ilona.app

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri

/**
 * The pairing secret for the companion's installer, read over adb with
 * `content query --uri content://tv.ilona.app.pairing/secret`, which prints `Row: 0 secret=<32 hex>`
 * (`secret=NULL` before IlonaTv's first launch has made one). The manifest guards it with DUMP, which the adb shell
 * holds and ordinary apps cannot. Pairing with the secret renews it, so each read pairs once.
 */
class PairingProvider : ContentProvider() {
    override fun onCreate() = true

    override fun query(uri: Uri, projection: Array<out String>?, selection: String?, selectionArgs: Array<out String>?, sortOrder: String?): Cursor {
        val secret = context!!.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
            .getString("flutter.companionSecret", null)
        return MatrixCursor(arrayOf("secret")).apply { addRow(arrayOf(secret)) }
    }

    override fun getType(uri: Uri): String? = null
    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
}
