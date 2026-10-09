package com.chalonasoft.apkserver

import android.app.ActivityManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

/**
 * Instala el APK bajado. SIN PREGUNTAR cuando Android lo deja.
 *
 * Desde Android 12 una app puede actualizarse a sí misma sin el diálogo del
 * sistema: sesión de [PackageInstaller] con `USER_ACTION_NOT_REQUIRED`,
 * `UPDATE_PACKAGES_WITHOUT_USER_ACTION` en el manifiesto y la persona con
 * «Permitir de esta fuente» activado para la app. Android cierra la app, la
 * reemplaza y no avisa a nadie. Probado en Android 15.
 *
 * La app NO se vuelve a abrir sola: Android bloquea abrir una pantalla desde
 * el receptor del resultado («Background activity launch blocked», probado en
 * Android 15). Una app con un servicio lo vuelve a levantar con
 * `MY_PACKAGE_REPLACED`; una con pantalla, la persona la abre de nuevo.
 *
 * Cuando hace falta la persona —Android 11 o menos, sin «Permitir de esta
 * fuente», o Android pide confirmar igual— y se pidió `conDialogo` con la app
 * al frente, se abre la pantalla del sistema. Si no, no se insiste: lo dice el
 * resultado y queda la notificación de «lista».
 */
internal object Instalador {
    private const val TAG = "apk_server"
    const val ACCION = "com.chalonasoft.apkserver.INSTALACION"

    /** Si Android no contesta en este tiempo, se devuelve el botón. Si instala sin preguntar no contesta: cierra la app. */
    private const val ESPERA_MS = 120_000L

    private class Espera(val conDialogo: Boolean, val listo: (String) -> Unit)

    /** Sesiones en vuelo → a quién contestarle cuando Android diga algo. */
    private val esperando = ConcurrentHashMap<Int, Espera>()
    private val principal = Handler(Looper.getMainLooper())

    /** ¿Una instalación ahora mismo iría sin preguntar? */
    fun sinPreguntar(ctx: Context): Boolean =
        Build.VERSION.SDK_INT >= 31 && ctx.packageManager.canRequestPackageInstalls()

    /** ¿Hay una pantalla de la app a la vista? Solo entonces se puede abrir la del sistema. */
    fun alFrente(): Boolean {
        val i = ActivityManager.RunningAppProcessInfo()
        ActivityManager.getMyMemoryState(i)
        return i.importance == ActivityManager.RunningAppProcessInfo.IMPORTANCE_FOREGROUND
    }

    fun instalar(ctx: Context, apk: File, conDialogo: Boolean, listo: (String) -> Unit) {
        val app = ctx.applicationContext
        if (!apk.isFile) {
            listo("error")
            return
        }
        val fuente = Build.VERSION.SDK_INT < 26 || app.packageManager.canRequestPackageInstalls()
        if (!fuente) {
            // Sin «Permitir de esta fuente» la sesión acabaría pidiendo
            // confirmar: ni se copia el APK. El instalador de siempre lleva a
            // la persona a dar el permiso, y la próxima ya va sola.
            if (conDialogo && alFrente()) {
                listo(if (abrirInstalador(app, apk)) "dialogo" else "error")
            } else {
                listo("permiso")
            }
            return
        }
        if (Build.VERSION.SDK_INT < 31 && !(conDialogo && alFrente())) {
            // Antes de Android 12 siempre pregunta: no tiene caso armar la sesión.
            listo("no_soportado")
            return
        }
        // Copiar decenas de MB a la sesión no va en el hilo principal.
        thread(name = "apk-server-instalar") {
            val instalador = app.packageManager.packageInstaller
            var id = -1
            try {
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(app.packageName)
                    setSize(apk.length())
                    if (Build.VERSION.SDK_INT >= 31) {
                        setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
                    }
                }
                id = instalador.createSession(params)
                esperando[id] = Espera(conDialogo, listo)
                instalador.openSession(id).use { sesion ->
                    sesion.openWrite("base.apk", 0, apk.length()).use { salida ->
                        apk.inputStream().use { it.copyTo(salida) }
                        sesion.fsync(salida)
                    }
                    val i = Intent(app, InstalacionReceiver::class.java).setAction(ACCION)
                    // MUTABLE: el instalador del sistema le agrega el resultado.
                    val pi = PendingIntent.getBroadcast(
                        app, id, i,
                        PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0),
                    )
                    sesion.commit(pi.intentSender)
                }
                val sesion = id
                principal.postDelayed({ esperando.remove(sesion)?.listo?.invoke("sin_respuesta") }, ESPERA_MS)
                // Desde aquí instala Android. Si va sin preguntar, cierra este
                // proceso: la respuesta llega (si llega) al proceso nuevo.
            } catch (e: Exception) {
                Log.w(TAG, "No se pudo armar la instalación", e)
                if (id >= 0) {
                    esperando.remove(id)
                    runCatching { instalador.abandonSession(id) }
                }
                listo("error")
            }
        }
    }

    /** El instalador de siempre, con el APK por [ApkProvider]. */
    fun abrirInstalador(ctx: Context, apk: File): Boolean = try {
        ctx.startActivity(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(ApkProvider.uri(ctx, apk), "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK),
        )
        true
    } catch (e: Exception) {
        Log.w(TAG, "No se pudo abrir el instalador", e)
        false
    }

    internal fun resultado(ctx: Context, intent: Intent) {
        val id = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val estado = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val e = esperando.remove(id)
        when (estado) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                @Suppress("DEPRECATION")
                val confirmar = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
                if (e != null && e.conDialogo && confirmar != null && alFrente()) {
                    // La pantalla del sistema para ESTA sesión: confirma y sigue.
                    try {
                        ctx.startActivity(confirmar.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        e.listo("dialogo")
                        return
                    } catch (x: Exception) {
                        Log.w(TAG, "No se pudo abrir la confirmación", x)
                    }
                }
                // Nadie a quien preguntarle ahora: se suelta la sesión. Queda la
                // notificación de «lista»; al tocarla, la app está al frente.
                runCatching { ctx.packageManager.packageInstaller.abandonSession(id) }
                e?.listo?.invoke("confirmar")
            }
            // Casi siempre llega al proceso NUEVO: el viejo lo cerró Android al
            // reemplazar la app, y aquí nadie espera.
            PackageInstaller.STATUS_SUCCESS -> e?.listo?.invoke("instalada")
            else -> {
                // FAILURE_ABORTED sin nadie esperando es el eco de soltar la sesión.
                if (e != null) {
                    Log.w(TAG, "La instalación falló ($estado): ${intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)}")
                    e.listo("error")
                }
            }
        }
    }
}

class InstalacionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == Instalador.ACCION) Instalador.resultado(context, intent)
    }
}

/**
 * Android terminó de reemplazar la app por la versión nueva: fuera el APK
 * bajado y su notificación de «lista». Sin esto la notificación se quedaba
 * hasta que alguien abriera la app.
 */
class ActualizadaReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val p = goAsync()
        thread(name = "apk-server-actualizada") {
            try {
                ApkServer.alArrancar(context.applicationContext)
            } finally {
                p.finish()
            }
        }
    }
}
