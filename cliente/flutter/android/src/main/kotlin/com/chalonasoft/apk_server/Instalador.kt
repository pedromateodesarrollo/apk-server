package com.chalonasoft.apk_server

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Instala la actualización SIN preguntar cuando Android lo deja.
 *
 * Desde Android 12 una app puede actualizarse a sí misma sin el diálogo del
 * sistema: sesión de [PackageInstaller] con `USER_ACTION_NOT_REQUIRED`,
 * `UPDATE_PACKAGES_WITHOUT_USER_ACTION` en el manifiesto y la persona con
 * «Permitir de esta fuente» activado para la app. Android cierra la app, la
 * reemplaza y no avisa a nadie. Probado en Android 15.
 *
 * La app NO se vuelve a abrir sola: Android bloquea abrir una pantalla desde
 * el receptor del resultado («Background activity launch blocked», probado en
 * Android 15). La persona la abre de nuevo; por eso Dart avisa antes.
 *
 * Cuando no se puede —Android 11 o menos, sin el permiso de la fuente, o
 * Android pide confirmar igual— no se insiste: se le dice a Dart y Dart abre
 * el instalador de siempre (OpenFilex).
 *
 * CUÁNDO se instala no se decide aquí: lo decide la app (`autoInstalar`,
 * `puedeInstalar`, el botón). Llamar a [instalar] es cerrar la app.
 */
internal object Instalador {
    private const val TAG = "apk_server"
    const val ACCION = "com.chalonasoft.apk_server.INSTALACION"

    /** Sesiones en vuelo → a quién contestarle cuando Android diga algo. */
    private val esperando = ConcurrentHashMap<Int, (Map<String, Any?>) -> Unit>()

    /** ¿Una instalación ahora mismo iría sin preguntar? */
    fun sinPreguntar(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= 31 && ctx.packageManager.canRequestPackageInstalls()

    fun instalar(ctx: Context, apk: File, listo: (Map<String, Any?>) -> Unit) {
        if (Build.VERSION.SDK_INT < 31) {
            listo(mapOf("resultado" to "no_soportado"))
            return
        }
        if (!ctx.packageManager.canRequestPackageInstalls()) {
            // Sin «Permitir de esta fuente» la sesión acabaría pidiendo
            // confirmar: ni se copia el APK. El instalador de siempre lleva a
            // la persona a dar el permiso, y la próxima ya va sola.
            listo(mapOf("resultado" to "permiso"))
            return
        }
        if (!apk.isFile) {
            listo(mapOf("resultado" to "error", "mensaje" to "No está el APK: ${apk.path}"))
            return
        }
        // Copiar decenas de MB a la sesión no va en el hilo principal.
        thread(name = "apk-server") {
            val instalador = ctx.packageManager.packageInstaller
            var id = -1
            try {
                val params = PackageInstaller.SessionParams(
                    PackageInstaller.SessionParams.MODE_FULL_INSTALL,
                ).apply {
                    setAppPackageName(ctx.packageName)
                    setSize(apk.length())
                    setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                }
                id = instalador.createSession(params)
                esperando[id] = listo
                instalador.openSession(id).use { sesion ->
                    sesion.openWrite("base.apk", 0, apk.length()).use { salida ->
                        apk.inputStream().use { it.copyTo(salida) }
                        sesion.fsync(salida)
                    }
                    val i = Intent(ctx, InstalacionReceiver::class.java).setAction(ACCION)
                    // MUTABLE: el instalador del sistema le agrega el resultado.
                    val pi = PendingIntent.getBroadcast(
                        ctx, id, i,
                        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE,
                    )
                    sesion.commit(pi.intentSender)
                }
                // Desde aquí instala Android. Si va sin preguntar, cierra este
                // proceso: la respuesta llega (si llega) al proceso nuevo.
            } catch (e: Exception) {
                Log.w(TAG, "No se pudo armar la instalación", e)
                if (id >= 0) {
                    esperando.remove(id)
                    runCatching { instalador.abandonSession(id) }
                }
                listo(mapOf("resultado" to "error", "mensaje" to (e.message ?: e.javaClass.simpleName)))
            }
        }
    }

    internal fun resultado(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val estado = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val listo = esperando.remove(id)
        when (estado) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                // Android quiere que alguien confirme. Se suelta la sesión y
                // Dart abre el instalador de siempre: un solo camino para todo
                // lo que necesita a la persona.
                runCatching { ctx.packageManager.packageInstaller.abandonSession(id) }
                listo?.invoke(mapOf("resultado" to "confirmar"))
            }
            PackageInstaller.STATUS_SUCCESS -> {
                // Casi siempre llega al proceso NUEVO: el viejo lo cerró Android
                // al reemplazar la app, y aquí nadie espera.
                listo?.invoke(mapOf("resultado" to "instalada"))
            }
            // El eco de soltar la sesión aquí arriba: ya se contestó.
            PackageInstaller.STATUS_FAILURE_ABORTED -> if (listo != null) {
                listo(mapOf("resultado" to "error", "mensaje" to "Se canceló la instalación"))
            }
            else -> {
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                Log.w(TAG, "La instalación falló ($estado): $msg")
                listo?.invoke(mapOf("resultado" to "error", "mensaje" to (msg ?: "La instalación falló ($estado)")))
            }
        }
    }
}

class InstalacionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Instalador.ACCION) Instalador.resultado(context, intent)
    }
}
