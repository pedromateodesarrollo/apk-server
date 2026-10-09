package com.chalonasoft.apkserver

import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * El WebSocket de avisos del hub (`/v1/ws?app=<slug>&instalacion=<clave>`).
 * Al publicar, el hub manda `{"tipo":"version", …}` y [alAviso] pregunta ya.
 * Mientras está abierto, el panel muestra el equipo como conectado.
 *
 * Reconecta solo, con espera creciente ([esperaMinMs]…[esperaMaxMs]), o en
 * cuanto vuelve la red ([rehacer], [reconectarAhora]). [alConectar] corre en
 * cada conexión: el aviso se reparte una sola vez a los sockets vivos, y lo
 * publicado mientras estaba caído solo se sabe preguntando.
 *
 * Todo su estado se toca en [hilo]; los callbacks de OkHttp llegan de otros
 * hilos y se pasan ahí.
 */
internal class Avisos(
    /** Se pide al conectar: así toma el ping de los ajustes de ese momento. */
    private val httpDe: () -> OkHttpClient,
    private val hilo: ScheduledExecutorService,
    private val esperaMinMs: Long,
    private val esperaMaxMs: () -> Long,
    private val alConectar: () -> Unit,
    private val alAviso: () -> Unit,
) {
    private var http: OkHttpClient? = null

    private var url: String? = null
    private var app: String = ""
    private var socket: WebSocket? = null
    private var abierto = false
    private var activo = false
    private var espera = esperaMinMs
    private var reconexion: ScheduledFuture<*>? = null

    val conectado: Boolean get() = abierto

    /** Conecta y se queda reconectando hasta [cerrar]. Idempotente. */
    fun conectar(hub: String, app: String, instalacion: String) {
        val u = urlDe(hub, app, instalacion) ?: return
        if (activo && u == url) return
        cerrar()
        url = u
        this.app = app
        activo = true
        espera = esperaMinMs
        abrir()
    }

    fun cerrar() {
        activo = false
        reconexion?.cancel(false)
        reconexion = null
        socket?.close(1000, null)
        socket = null
        abierto = false
    }

    /** Si está esperando para reintentar, reintenta ya (la app volvió al frente). */
    fun reconectarAhora() {
        if (!activo || socket != null) return
        reconexion?.cancel(false)
        espera = esperaMinMs
        abrir()
    }

    /** La red cambió (Wi-Fi ↔ datos): el socket viejo quedó colgado de la anterior. */
    fun rehacer() {
        if (!activo) return
        socket?.cancel()
        socket = null
        abierto = false
        reconexion?.cancel(false)
        espera = esperaMinMs
        abrir()
    }

    private fun abrir() {
        val u = url ?: return
        if (!activo || socket != null) return
        val h = http ?: httpDe().also { http = it }
        socket = h.newWebSocket(Request.Builder().url(u).build(), Oyente())
    }

    private fun caido(ws: WebSocket) {
        if (socket !== ws) return
        socket = null
        abierto = false
        if (!activo) return
        reconexion = hilo.schedule({ reconexion = null; abrir() }, espera, TimeUnit.MILLISECONDS)
        espera = minOf(espera * 2, maxOf(esperaMinMs, esperaMaxMs()))
    }

    private inner class Oyente : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            hilo.execute {
                if (socket !== webSocket) return@execute
                abierto = true
                espera = esperaMinMs
                alConectar()
            }
        }

        override fun onMessage(webSocket: WebSocket, text: String) {
            val d = try {
                JSONObject(text)
            } catch (_: Exception) {
                return
            }
            if (d.optString("tipo") != "version") return
            val de = d.optString("app")
            hilo.execute {
                if (socket !== webSocket) return@execute
                if (de.isNotEmpty() && de != app) return@execute
                alAviso()
            }
        }

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(1000, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            hilo.execute { caido(webSocket) }
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            hilo.execute { caido(webSocket) }
        }
    }

    companion object {
        /** `https://hub` → `wss://hub/v1/ws?app=…&instalacion=…` (OkHttp acepta http/https). */
        fun urlDe(hub: String, app: String, instalacion: String): String? {
            val base = hub.trimEnd('/').toHttpUrlOrNull() ?: return null
            return base.newBuilder()
                .addPathSegments("v1/ws")
                .addQueryParameter("app", app)
                .addQueryParameter("instalacion", instalacion)
                .build()
                .toString()
        }
    }
}
