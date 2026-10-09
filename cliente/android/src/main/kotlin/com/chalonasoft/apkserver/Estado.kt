package com.chalonasoft.apkserver

/** En qué anda la actualización. [clave] es lo que viaja al plugin de Flutter. */
enum class Fase(val clave: String) {
    /** Nada que hacer, o todavía no se sabe. */
    AL_DIA("al_dia"),

    /** Preguntando al hub, a pedido de alguien (las del sondeo no se anuncian). */
    VERIFICANDO("verificando"),

    /** Hay versión, pero la red tiene medidor y la app pidió bajar solo con Wi-Fi. */
    ESPERANDO_WIFI("esperando_wifi"),

    DESCARGANDO("descargando"),

    /** El APK está bajado y completo: falta instalarlo. */
    LISTO("listo"),

    /** Android está instalando: la app se va a cerrar sola en unos segundos. */
    INSTALANDO("instalando"),

    /**
     * Algo falló. Con [Estado.version], es una descarga que se cortó y que
     * sigue sola; sin ella, el hub no contestó a una consulta pedida a mano.
     */
    ERROR("error"),
}

/**
 * Lo que se le enseña a la persona. Se reemplaza entero en cada cambio: quien
 * lo guarda tiene una foto, no una referencia viva.
 */
data class Estado(
    val fase: Fase = Fase.AL_DIA,
    /** 0..1, de la descarga. */
    val progreso: Double = 0.0,
    val version: String? = null,
    val build: Long = 0,
    val requerido: Boolean = false,
    /** Ruta del APK completo (con [Fase.LISTO] y [Fase.INSTALANDO]). */
    val apk: String? = null,
    val error: String? = null,
    /**
     * Con [Fase.LISTO], por qué no se instala sin preguntar: `permiso` (falta
     * «Permitir de esta fuente»), `confirmar` (Android pidió que alguien
     * confirme) o null (se puede).
     */
    val falta: String? = null,
) {
    fun aMapa(): Map<String, Any?> = mapOf(
        "fase" to fase.clave,
        "progreso" to progreso,
        "version" to version,
        "build" to build,
        "requerido" to requerido,
        "apk" to apk,
        "error" to error,
        "falta" to falta,
    )
}
