package com.chalonasoft.apkserver

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build

/**
 * Las notificaciones de la actualización. Una sola, que cambia: el avance
 * (si la app lo pidió) y al final «Actualización X lista — toca para
 * instalar». Sin androidx: `Notification.Builder` del sistema alcanza.
 *
 * Desde Android 13 la persona tiene que permitir las notificaciones de la
 * app; sin eso no sale nada y la app se actualiza igual.
 */
internal object Notificaciones {
    private const val CANAL_LISTA = "apk_server_lista"
    private const val CANAL_DESCARGA = "apk_server_descarga"
    private const val ID = 0x41504b53 // «APKS»

    fun mostrar(ctx: Context, ajustes: Ajustes, e: Estado) {
        when (e.fase) {
            Fase.LISTO -> if (ajustes.notificarLista) lista(ctx, ajustes, e)
            Fase.DESCARGANDO, Fase.ESPERANDO_WIFI -> if (ajustes.notificarDescarga) avance(ctx, ajustes, e)
            Fase.ERROR -> if (ajustes.notificarDescarga && e.version != null) avance(ctx, ajustes, e)
            Fase.AL_DIA -> quitar(ctx)
            // Instalando: la app se cierra en segundos; si no, vuelve a LISTO.
            Fase.VERIFICANDO, Fase.INSTALANDO -> Unit
        }
    }

    fun quitar(ctx: Context) {
        runCatching { gestor(ctx).cancel(ID) }
    }

    private fun lista(ctx: Context, ajustes: Ajustes, e: Estado) {
        val titulo = "Actualización ${e.version ?: ""} lista".replace("  ", " ") +
            if (e.requerido) " · obligatoria" else ""
        val texto = if (e.falta == "permiso") {
            "Toca para instalarla. Android te va a pedir que permitas a la app instalar " +
                "actualizaciones: actívalo una vez y las próximas se instalan solas."
        } else {
            "Toca para instalarla. La app se cierra y queda en la versión nueva."
        }
        val pi = PendingIntent.getActivity(
            ctx, 0,
            Intent(ctx, InstalarActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        publicar(
            ctx,
            constructor(ctx, CANAL_LISTA)
                .setSmallIcon(icono(ajustes))
                .setContentTitle(titulo)
                .setContentText(texto)
                .setStyle(Notification.BigTextStyle().bigText(texto))
                .setContentIntent(pi)
                // Se queda hasta que la versión se instala (la quita
                // [ActualizadaReceiver]) o se retira: si la persona la toca y
                // cancela la pantalla del sistema, sigue ahí para la próxima.
                .setAutoCancel(false)
                .setOnlyAlertOnce(true)
                .build(),
        )
    }

    private fun avance(ctx: Context, ajustes: Ajustes, e: Estado) {
        val v = e.version ?: ""
        val pct = (e.progreso * 100).toInt().coerceIn(0, 100)
        val b = constructor(ctx, CANAL_DESCARGA)
            .setSmallIcon(icono(ajustes))
            .setOnlyAlertOnce(true)
        when (e.fase) {
            Fase.DESCARGANDO -> b.setContentTitle("Bajando la actualización $v")
                .setContentText(if (pct > 0) "$pct %" else "Empezando…")
                .setProgress(100, pct, pct == 0)
                .setOngoing(true)
            Fase.ESPERANDO_WIFI -> b.setContentTitle("Actualización $v")
                .setContentText("Se baja en cuanto haya Wi-Fi.")
            else -> b.setContentTitle("Se cortó la descarga de la actualización $v")
                .setContentText("Sigue sola en cuanto haya conexión, desde donde quedó.")
        }
        publicar(ctx, b.build())
    }

    // getSystemService(Class) es de Android 6: con minSdk 21, por nombre.
    private fun gestor(ctx: Context) = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun icono(ajustes: Ajustes) =
        if (ajustes.icono != 0) ajustes.icono else android.R.drawable.stat_sys_download_done

    private fun constructor(ctx: Context, canal: String): Notification.Builder {
        if (Build.VERSION.SDK_INT < 26) {
            @Suppress("DEPRECATION")
            return Notification.Builder(ctx).also {
                if (canal == CANAL_DESCARGA) {
                    @Suppress("DEPRECATION")
                    it.setPriority(Notification.PRIORITY_LOW)
                }
            }
        }
        val nm = gestor(ctx)
        if (nm.getNotificationChannel(canal) == null) {
            val c = if (canal == CANAL_LISTA) {
                NotificationChannel(canal, "Actualización lista", NotificationManager.IMPORTANCE_DEFAULT)
                    .apply { description = "Cuando una versión nueva de la app terminó de bajar." }
            } else {
                NotificationChannel(canal, "Descarga de actualizaciones", NotificationManager.IMPORTANCE_LOW)
                    .apply { description = "El avance mientras baja una versión nueva." }
            }
            nm.createNotificationChannel(c)
        }
        return Notification.Builder(ctx, canal)
    }

    private fun publicar(ctx: Context, n: Notification) {
        if (Build.VERSION.SDK_INT >= 33 &&
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        runCatching { gestor(ctx).notify(ID, n) }
    }
}
