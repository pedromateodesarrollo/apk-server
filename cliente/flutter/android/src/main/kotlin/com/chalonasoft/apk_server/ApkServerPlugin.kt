package com.chalonasoft.apk_server

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * El canal `apk_server` entre Dart (`UpdateInstalador`, `UpdateService`) y
 * Android.
 *
 * - `equipo` → `{huella, modelo, fabricante, android}`: lo que el equipo
 *   cuenta de sí en cada consulta al hub.
 * - `sinPreguntar` → `true` si una instalación ahora no pediría confirmar.
 * - `instalar {ruta}` → `{resultado, mensaje?}`, con `resultado` uno de
 *   `confirmar | permiso | no_soportado | error | instalada`. Si Android
 *   instala sin preguntar, lo normal es que NO conteste: cierra la app para
 *   reemplazarla.
 */
class ApkServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var canal: MethodChannel? = null
    private var contexto: Context? = null
    private val principal = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contexto = binding.applicationContext
        canal = MethodChannel(binding.binaryMessenger, "apk_server").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        canal?.setMethodCallHandler(null)
        canal = null
        contexto = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = contexto
        if (ctx == null) {
            result.error("sin_contexto", "El plugin no está enganchado", null)
            return
        }
        when (call.method) {
            "equipo" -> result.success(equipo(ctx))
            "sinPreguntar" -> result.success(Instalador.sinPreguntar(ctx))
            "instalar" -> {
                val ruta = call.argument<String>("ruta")
                if (ruta == null) {
                    result.error("sin_ruta", "Falta la ruta del APK", null)
                    return
                }
                // El resultado llega desde otro hilo (la copia del APK) o desde el
                // receptor del instalador; el canal se contesta en el principal.
                Instalador.instalar(ctx, File(ruta)) { r -> principal.post { result.success(r) } }
            }
            else -> result.notImplemented()
        }
    }

    /**
     * El ANDROID_ID es la huella del equipo: sobrevive a desinstalar y
     * reinstalar la app, y es el mismo para todas las apps firmadas con la
     * misma llave en ese equipo. Cambia con un reseteo de fábrica. No pide
     * ningún permiso (el IMEI y el número de serie sí, y ya no se dan).
     */
    @SuppressLint("HardwareIds")
    private fun equipo(ctx: Context): Map<String, Any?> = mapOf(
        "huella" to Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID),
        "modelo" to Build.MODEL,
        "fabricante" to Build.MANUFACTURER,
        "android" to Build.VERSION.SDK_INT,
    )
}
