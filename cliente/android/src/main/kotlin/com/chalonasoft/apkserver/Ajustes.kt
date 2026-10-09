package com.chalonasoft.apkserver

import org.json.JSONObject

/**
 * Cómo se actualiza la app. Todo tiene un valor por defecto: lo único que
 * hace falta es el hub y el slug, y esos vienen del manifiesto
 * (`manifestPlaceholders` `apkServerHub` y `apkServerApp`).
 */
class Ajustes {
    /** `https://apk.ejemplo.com`. Vacío = el del manifiesto. */
    var hub: String = ""

    /** Slug de la app en el hub. Vacío = el del manifiesto. */
    var app: String = ""

    /** Abrir el WebSocket del hub en `iniciar()`: una versión publicada llega al instante. */
    var avisos: Boolean = true

    /** Cada cuánto se pregunta por si el aviso no llegó (Doze corta la red). */
    var intervaloMs: Long = 3_600_000L

    /** Freno: dos consultas que no son a pedido no van más seguidas que esto. */
    var minEntreChequeosMs: Long = 5 * 60_000L

    /**
     * Esperas entre un corte de la descarga y el siguiente intento: la
     * primera tras el primer corte… y la última de ahí en adelante. Mientras
     * la versión siga publicada no se abandona.
     */
    var esperasReintentoMs: List<Long> = listOf(5_000, 15_000, 30_000, 60_000, 120_000, 300_000)

    /** En segundo plano, bajar solo con Wi-Fi (el APK pesa decenas de MB). A pedido baja igual. */
    var soloWifi: Boolean = false

    /**
     * Al terminar de bajar, instalar sola si va sin preguntar (Android 12+ con
     * «Permitir de esta fuente»). Instalar CIERRA la app: para una que corre de
     * fondo está bien; una con pantalla decide el momento ([puedeInstalar], o
     * el botón).
     */
    var autoInstalar: Boolean = false

    /** Con [autoInstalar], además tiene que devolver true en el momento. */
    var puedeInstalar: () -> Boolean = { true }

    /** La notificación de «Actualización X lista — toca para instalar». */
    var notificarLista: Boolean = true

    /** Una notificación callada con el avance mientras baja. */
    var notificarDescarga: Boolean = false

    /** Icono de las notificaciones (monocromo). 0 = el del sistema. */
    var icono: Int = 0

    /**
     * Lo que la app quiera contar en cada consulta (empresa, usuario con
     * sesión…). Lo ve quien administra el hub. Corre fuera del hilo principal,
     * en cada consulta; null = lo último que se contó.
     */
    var contexto: (() -> JSONObject?)? = null

    /** Ping del socket. Con un servicio que corre todo el día, más espaciado gasta menos batería. */
    var pingSegundos: Long = 30

    /** Tope de la espera entre reconexiones del socket. */
    var esperaMaxAvisosMs: Long = 32_000L

    /** Cuánto se espera sin que llegue un byte antes de dar la descarga por cortada. */
    var sinDatosMs: Long = 45_000L
}
