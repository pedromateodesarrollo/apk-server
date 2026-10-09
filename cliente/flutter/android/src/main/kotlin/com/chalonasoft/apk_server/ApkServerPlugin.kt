package com.chalonasoft.apk_server

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chalonasoft.apkserver.ApkServer
import com.chalonasoft.apkserver.Actualizacion
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * El canal `apk_server` entre Dart (`UpdateService`) y la biblioteca de
 * Android (`com.chalonasoft.apkserver`), que es la que hace todo: Dart solo
 * dice cuándo y enseña el estado.
 *
 * Dart → Android:
 * - `configurar {hub?, app?, avisos, intervaloMs, minEntreChequeosMs, esperasMs}`
 *   → `{hub, app, urlInstalar, instalacion, estado}`
 * - `iniciar`, `detener`, `alVolverAlFrente`
 * - `verificar {forzar, manual}` → cuando el hub contestó
 * - `instalar {conDialogo}` → `{resultado}`
 * - `sinPreguntar` → bool; `estado` → mapa; `equipo` → `{huella, modelo, fabricante, android}`
 *
 * Android → Dart:
 * - `estado` con cada cambio.
 * - `contexto` antes de cada consulta: lo que la app quiera contar. Si Dart no
 *   contesta en 2 s (o no hay motor), va lo último que contó.
 */
class ApkServerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private var canal: MethodChannel? = null
    private var contexto: Context? = null
    private var dejarDeEscuchar: (() -> Unit)? = null
    private val principal = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        contexto = binding.applicationContext
        canal = MethodChannel(binding.binaryMessenger, "apk_server").also {
            it.setMethodCallHandler(this)
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        dejarDeEscuchar?.invoke()
        dejarDeEscuchar = null
        contexto?.let { ApkServer.de(it).ajustes.contexto = null }
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
        val a = ApkServer.de(ctx)
        when (call.method) {
            "configurar" -> {
                configurar(a, call)
                result.success(
                    mapOf(
                        "hub" to a.hub,
                        "app" to a.app,
                        "urlInstalar" to a.urlInstalar,
                        "instalacion" to a.instalacion,
                        "estado" to a.estado.aMapa(),
                    ),
                )
            }
            "iniciar" -> {
                a.iniciar()
                result.success(null)
            }
            "detener" -> {
                a.detener()
                result.success(null)
            }
            "alVolverAlFrente" -> {
                a.alVolverAlFrente()
                result.success(null)
            }
            "verificar" -> a.verificar(
                forzar = call.argument<Boolean>("forzar") ?: false,
                manual = call.argument<Boolean>("manual") ?: false,
            ) { result.success(null) }
            "instalar" -> a.instalar(conDialogo = call.argument<Boolean>("conDialogo") ?: true) { r ->
                result.success(mapOf("resultado" to r))
            }
            "sinPreguntar" -> result.success(a.sinPreguntar())
            "estado" -> result.success(a.estado.aMapa())
            "equipo" -> result.success(a.equipo())
            else -> result.notImplemented()
        }
    }

    private fun configurar(a: Actualizacion, call: MethodCall) {
        val aj = a.ajustes
        call.argument<String>("hub")?.let { aj.hub = it }
        call.argument<String>("app")?.let { aj.app = it }
        call.argument<Boolean>("avisos")?.let { aj.avisos = it }
        call.argument<Number>("intervaloMs")?.let { aj.intervaloMs = it.toLong() }
        call.argument<Number>("minEntreChequeosMs")?.let { aj.minEntreChequeosMs = it.toLong() }
        call.argument<List<Number>>("esperasMs")?.let { l -> aj.esperasReintentoMs = l.map { it.toLong() } }
        // Instalar lo decide Dart (`autoInstalar`, `puedeInstalar`): sabe si la
        // app está al frente y a mitad de qué.
        aj.autoInstalar = false
        aj.contexto = { pedirContexto() }
        if (dejarDeEscuchar == null) {
            dejarDeEscuchar = a.escuchar { e -> canal?.invokeMethod("estado", e.aMapa()) }
        }
    }

    /** Le pregunta a Dart el contexto. Corre fuera del hilo principal (en la consulta). */
    private fun pedirContexto(): JSONObject? {
        val c = canal ?: return null
        if (Looper.myLooper() == Looper.getMainLooper()) return null
        val listo = CountDownLatch(1)
        var r: JSONObject? = null
        principal.post {
            c.invokeMethod(
                "contexto", null,
                object : MethodChannel.Result {
                    override fun success(v: Any?) {
                        r = (v as? Map<*, *>)?.let { m -> JSONObject(m.mapKeys { it.key.toString() }) }
                        listo.countDown()
                    }

                    override fun error(code: String, msg: String?, details: Any?) = listo.countDown()
                    override fun notImplemented() = listo.countDown()
                },
            )
        }
        listo.await(2, TimeUnit.SECONDS)
        return r
    }
}
