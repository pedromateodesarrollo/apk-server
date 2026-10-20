package com.chalonasoft.apkserver

import android.app.Activity
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.graphics.PixelFormat
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.util.Log
import android.view.View
import android.view.WindowManager

/**
 * Que la app vuelva a abrirse sola después de actualizarse.
 *
 * Instalar una versión nueva MATA el proceso de la app, y Android no la vuelve
 * a abrir. Abrirla uno mismo desde el receptor de `MY_PACKAGE_REPLACED` lo
 * bloquea Android 10+ («Background activity launch blocked»). Medido en un
 * Samsung A55 con Android 16:
 *
 *  - `startActivity` desde el receptor ........................ bloqueado
 *  - desde un servicio en primer plano ........................ bloqueado
 *  - un `PendingIntent` de actividad como destino del instalador  bloqueado
 *  - una notificación con pantalla completa, con la pantalla encendida:
 *    solo sale el aviso (no abre nada)
 *  - **con «Mostrar sobre otras apps» y una ventana transparente de 1 px
 *    visible, `startActivity` pasa** (`BAL_ALLOW_NON_APP_VISIBLE_WINDOW`).
 *
 * Por eso: si la app tiene ese permiso (se da una vez, en Ajustes), se abre
 * sola. Si no, queda una notificación «se actualizó — toca para abrirla»
 * (con pantalla completa si la pantalla está apagada), con un botón para
 * activar el permiso. Antes de Android 10 se abre directo.
 *
 * La decisión de reabrir se toma ANTES de instalar y queda anotada en disco
 * ([marcar]): el proceso que recibe el `MY_PACKAGE_REPLACED` es otro, nuevo,
 * que no conoce los ajustes.
 */
internal object Reabrir {
    private const val TAG = "apk_server"
    private const val PREFS = "apk_server"
    private const val MARCA = "reabrir_marca"
    private const val AVISO_PERMISO = "reabrir_aviso_permiso"
    private const val CANAL = "apk_server_abrir"
    private const val ID_ABRIR = 0x41504b54
    private const val ID_PERMISO = 0x41504b55

    /** Cuánto vale la anotación: la instalación sin preguntar tarda segundos; la que pide confirmar, algo más. */
    private const val VIGENCIA_MS = 10 * 60_000L

    const val EXTRA = "com.chalonasoft.apkserver.REABIERTA_TRAS_ACTUALIZAR"

    private val principal = Handler(Looper.getMainLooper())

    private fun prefs(ctx: Context) = ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** La pantalla de entrada de la app, o null si no tiene (un servicio sin pantalla no se abre). */
    private fun entrada(ctx: Context): Intent? =
        ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            ?.putExtra(EXTRA, true)

    /** ¿Se puede abrir la app sola, sin tocar nada? Antes de Android 10 siempre; después, con «Mostrar sobre otras apps». */
    fun puedeSola(ctx: Context): Boolean = Build.VERSION.SDK_INT < 29 || Settings.canDrawOverlays(ctx)

    /** Anota que, al terminar de instalar, la app tiene que volver a abrirse. */
    fun marcar(ctx: Context, ajustes: Ajustes) {
        if (!ajustes.reabrir || entrada(ctx) == null) return
        prefs(ctx).edit().putLong(MARCA, System.currentTimeMillis()).commit()
    }

    /** La instalación no siguió (falló, hace falta confirmar…): la app sigue abierta. */
    fun desmarcar(ctx: Context) {
        prefs(ctx).edit().remove(MARCA).apply()
    }

    /**
     * Desde `MY_PACKAGE_REPLACED`, en el hilo principal. Abre la app si estaba
     * anotado; [fin] se llama cuando ya no hace falta mantener vivo el proceso.
     */
    fun alReemplazar(ctx: Context, fin: () -> Unit) {
        val p = prefs(ctx)
        val marca = p.getLong(MARCA, 0)
        if (marca <= 0) return fin()
        p.edit().remove(MARCA).commit()
        val intento = entrada(ctx)
        if (intento == null || System.currentTimeMillis() - marca > VIGENCIA_MS) return fin()
        try {
            if (Build.VERSION.SDK_INT < 29) {
                ctx.startActivity(intento)
                fin()
            } else if (Settings.canDrawOverlays(ctx)) {
                conVentana(ctx, intento, fin)
            } else {
                avisar(ctx, intento, conAccionPermiso = true)
                fin()
            }
        } catch (e: Exception) {
            Log.w(TAG, "No se pudo reabrir la app", e)
            runCatching { avisar(ctx, intento, conAccionPermiso = false) }
            fin()
        }
    }

    /**
     * Una ventana transparente de 1 px, visible, le da a la app derecho a abrir
     * una pantalla desde segundo plano. Se abre a los 0,3 s y se reintenta si no
     * pegó; si a los 4 s no hay pantalla, queda el aviso.
     */
    private fun conVentana(ctx: Context, intento: Intent, fin: () -> Unit) {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as WindowManager
        val ventana = View(ctx)
        val app = ctx.applicationContext as Application
        var abierta = false
        val oyente = object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) { abierta = true }
            override fun onActivityCreated(a: Activity, s: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, s: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        }
        app.registerActivityLifecycleCallbacks(oyente)
        val puesta = runCatching {
            @Suppress("DEPRECATION")
            val tipo = if (Build.VERSION.SDK_INT >= 26) WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            else WindowManager.LayoutParams.TYPE_PHONE
            wm.addView(
                ventana,
                WindowManager.LayoutParams(
                    1, 1, tipo,
                    WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
                    PixelFormat.TRANSLUCENT,
                ),
            )
        }.onFailure { Log.w(TAG, "No se pudo poner la ventana", it) }.isSuccess
        fun abrir() {
            if (!abierta) runCatching { ctx.startActivity(intento) }.onFailure { Log.w(TAG, "startActivity", it) }
        }
        principal.postDelayed(::abrir, if (puesta) 300 else 0)
        principal.postDelayed(::abrir, 1_500)
        principal.postDelayed(::abrir, 3_000)
        principal.postDelayed({
            runCatching { wm.removeView(ventana) }
            app.unregisterActivityLifecycleCallbacks(oyente)
            if (!abierta) runCatching { avisar(ctx, intento, conAccionPermiso = false) }
            fin()
        }, 4_000)
    }

    private fun gestor(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun canal(ctx: Context) {
        if (Build.VERSION.SDK_INT >= 26 && gestor(ctx).getNotificationChannel(CANAL) == null) {
            gestor(ctx).createNotificationChannel(
                NotificationChannel(CANAL, "Actualización instalada", NotificationManager.IMPORTANCE_HIGH)
                    .apply { description = "Cuando la app se actualizó y hay que abrirla otra vez." },
            )
        }
    }

    private fun constructor(ctx: Context): Notification.Builder {
        canal(ctx)
        @Suppress("DEPRECATION")
        return if (Build.VERSION.SDK_INT >= 26) Notification.Builder(ctx, CANAL)
        else Notification.Builder(ctx).setPriority(Notification.PRIORITY_HIGH)
    }

    private fun puedePublicar(ctx: Context) =
        Build.VERSION.SDK_INT < 33 ||
            ctx.checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) == android.content.pm.PackageManager.PERMISSION_GRANTED

    private fun nombre(ctx: Context) = ctx.applicationInfo.loadLabel(ctx.packageManager).toString()

    private fun pantallaPermiso(ctx: Context): Intent =
        Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION, Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    /** «Se actualizó — toca para abrirla». Con la pantalla apagada abre sola (pantalla completa). */
    private fun avisar(ctx: Context, intento: Intent, conAccionPermiso: Boolean) {
        if (!puedePublicar(ctx)) return
        val abrir = PendingIntent.getActivity(ctx, 1, intento, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val b = constructor(ctx)
            .setSmallIcon(android.R.drawable.stat_sys_download_done)
            .setContentTitle("${nombre(ctx)} se actualizó")
            .setContentText("Toca para abrirla.")
            .setContentIntent(abrir)
            .setAutoCancel(true)
        if (Build.VERSION.SDK_INT >= 34 && gestor(ctx).canUseFullScreenIntent() || Build.VERSION.SDK_INT in 29..33) {
            b.setFullScreenIntent(abrir, true)
        }
        if (conAccionPermiso && Build.VERSION.SDK_INT >= 29) {
            val permiso = PendingIntent.getActivity(ctx, 2, pantallaPermiso(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            @Suppress("DEPRECATION")
            b.addAction(Notification.Action.Builder(null as android.graphics.drawable.Icon?, "Que se abra sola", permiso).build())
        }
        runCatching { gestor(ctx).notify(ID_ABRIR, b.build()) }
    }

    /** La pantalla de Ajustes de «Mostrar sobre otras apps» para esta app. */
    fun pedirPermiso(desde: Context) {
        if (Build.VERSION.SDK_INT < 29) return
        runCatching { desde.startActivity(pantallaPermiso(desde)) }
    }

    @Volatile private var vigilando = false

    /** Quita «se actualizó» en cuanto la app se abre (por donde sea). Una vez por proceso. */
    fun vigilarApertura(app: Application) {
        if (vigilando) return
        vigilando = true
        app.registerActivityLifecycleCallbacks(object : Application.ActivityLifecycleCallbacks {
            override fun onActivityResumed(a: Activity) {
                runCatching { gestor(app).cancel(ID_ABRIR) }
            }
            override fun onActivityCreated(a: Activity, s: Bundle?) {}
            override fun onActivityStarted(a: Activity) {}
            override fun onActivityPaused(a: Activity) {}
            override fun onActivityStopped(a: Activity) {}
            override fun onActivitySaveInstanceState(a: Activity, s: Bundle) {}
            override fun onActivityDestroyed(a: Activity) {}
        })
    }

    /**
     * Una sola vez en la vida de la instalación: si la app no puede abrirse
     * sola, una notificación dice qué activar (un toque lleva a Ajustes).
     */
    fun avisarPermiso(ctx: Context, ajustes: Ajustes) {
        if (!ajustes.reabrir || !ajustes.avisarReabrirSola || puedeSola(ctx) || entrada(ctx) == null) return
        val p = prefs(ctx)
        if (p.getBoolean(AVISO_PERMISO, false) || !puedePublicar(ctx)) return
        p.edit().putBoolean(AVISO_PERMISO, true).apply()
        val pi = PendingIntent.getActivity(ctx, 2, pantallaPermiso(ctx), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        runCatching {
            gestor(ctx).notify(
                ID_PERMISO,
                constructor(ctx)
                    .setSmallIcon(android.R.drawable.stat_sys_download_done)
                    .setContentTitle("Que ${nombre(ctx)} se abra sola al actualizarse")
                    .setContentText("Activa «Mostrar sobre otras apps» para ${nombre(ctx)}. Si no, tendrás que abrirla tú.")
                    .setStyle(Notification.BigTextStyle().bigText("Activa «Mostrar sobre otras apps» para ${nombre(ctx)}. Si no, después de cada actualización tendrás que abrirla tú."))
                    .setContentIntent(pi)
                    .setAutoCancel(true)
                    .build(),
            )
        }
    }
}
