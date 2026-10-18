package com.chalonasoft.apkserver

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * Que la app se vuelva a abrir sola después de que el actualizador la
 * reemplaza.
 *
 * Android cierra la app al instalar la versión nueva y desde Android 10 no deja
 * abrir una pantalla desde segundo plano: el receptor de `MY_PACKAGE_REPLACED`
 * no puede («Background activity launch blocked», probado en Android 15). La
 * excepción es una app con «Mostrar sobre otras apps» (`SYSTEM_ALERT_WINDOW`)
 * concedido por la persona: esa sí puede abrir su pantalla de inicio. La app lo
 * pide con un botón ([abrirAjustes]); sin él, todo sigue como antes.
 *
 * Solo se reabre lo que el actualizador instaló con la app AL FRENTE: justo
 * antes de entregarle el APK a Android se deja una [marcar], que el receptor
 * gasta. Una instalación hecha con la app detrás (`autoInstalar` de fondo) o
 * una de afuera (adb, otra tienda) no trae marca y no abre nada.
 */
internal object Reabrir {
    private const val TAG = "apk_server"
    private const val PREFS = "apk_server"
    private const val MARCA = "reabrir_hasta"

    /** Tanto vale la marca: lo que puede tardar Android en copiar e instalar. */
    private const val VIGENCIA_MS = 10 * 60_000L

    /**
     * ¿Se abriría sola? Antes de Android 10 cualquiera podía abrir una pantalla
     * desde segundo plano; desde entonces hace falta «Mostrar sobre otras apps».
     */
    fun permitido(ctx: Context): Boolean =
        Build.VERSION.SDK_INT < 29 || Settings.canDrawOverlays(ctx)

    /** La pantalla de Android para dar (o quitar) «Mostrar sobre otras apps» a esta app. */
    fun abrirAjustes(ctx: Context): Boolean {
        if (Build.VERSION.SDK_INT < 23) return false
        val paquete = Uri.parse("package:${ctx.packageName}")
        for (i in listOf(
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, paquete),
            // Algunos fabricantes no aceptan el paquete: la lista de todas.
            Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION),
        )) {
            try {
                ctx.startActivity(i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return true
            } catch (e: Exception) {
                Log.w(TAG, "No se pudo abrir el ajuste de «Mostrar sobre otras apps»", e)
            }
        }
        return false
    }

    /** Justo antes de entregarle el APK a Android, si la app está al frente. */
    fun marcar(ctx: Context) {
        prefs(ctx).edit().putLong(MARCA, System.currentTimeMillis() + VIGENCIA_MS).commit()
    }

    /** La instalación no siguió (falló, se soltó la sesión): fuera la marca. */
    fun desmarcar(ctx: Context) {
        prefs(ctx).edit().remove(MARCA).apply()
    }

    /**
     * Desde `MY_PACKAGE_REPLACED`: si había marca vigente y hay permiso, abre la
     * pantalla de inicio de la app. La marca se gasta siempre.
     */
    fun alReemplazar(ctx: Context) {
        val p = prefs(ctx)
        val hasta = p.getLong(MARCA, 0)
        if (hasta == 0L) return
        p.edit().remove(MARCA).commit()
        if (System.currentTimeMillis() > hasta) return
        if (!permitido(ctx)) return
        val inicio = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName) ?: return
        try {
            ctx.startActivity(inicio.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo volver a abrir la app", e)
        }
    }

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
