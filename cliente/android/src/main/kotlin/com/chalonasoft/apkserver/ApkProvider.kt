package com.chalonasoft.apkserver

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Le pasa el APK bajado al instalador del sistema, cuando hace falta que la
 * persona confirme: solo lectura, solo los `.apk` de la carpeta de
 * actualizaciones, y solo a quien recibió el permiso de esa URI. Sin androidx:
 * un FileProvider entero para un archivo es mucho.
 *
 * Además, como Android crea los proveedores al arrancar el proceso (antes que
 * la app), aquí se limpia lo de una actualización que ya se instaló: el APK y
 * su notificación de «lista».
 */
class ApkProvider : ContentProvider() {
    override fun onCreate(): Boolean {
        val ctx = context ?: return true
        Thread({ runCatching { ApkServer.alArrancar(ctx.applicationContext) } }, "apk-server-arranque").start()
        return true
    }

    private fun archivo(uri: Uri): File? {
        val ctx = context ?: return null
        val nombre = uri.lastPathSegment ?: return null
        if (nombre.contains('/') || !nombre.endsWith(".apk")) return null
        return File(ApkServer.carpeta(ctx), nombre).takeIf { it.isFile }
    }

    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
        if (mode != "r") throw SecurityException("Solo lectura")
        val f = archivo(uri) ?: throw FileNotFoundException(uri.toString())
        return ParcelFileDescriptor.open(f, ParcelFileDescriptor.MODE_READ_ONLY)
    }

    override fun getType(uri: Uri) = "application/vnd.android.package-archive"

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor? {
        val f = archivo(uri) ?: return null
        return MatrixCursor(arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)).apply {
            addRow(arrayOf<Any>(f.name, f.length()))
        }
    }

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()
    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()

    companion object {
        fun uri(ctx: Context, apk: File): Uri =
            Uri.Builder().scheme("content").authority("${ctx.packageName}.apkserver").appendPath(apk.name).build()
    }
}
