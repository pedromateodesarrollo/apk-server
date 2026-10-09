package com.chalonasoft.apkserver

import okhttp3.OkHttpClient
import okhttp3.Request
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.security.MessageDigest

/**
 * Baja el APK de una versión a [carpeta] como `<prefijo>_<build>.apk`.
 *
 * Escribe primero en un `.part` y renombra al terminar, después de comprobar
 * el tamaño y el sha256 que dijo el hub: un archivo con ese nombre siempre es
 * un APK completo y es el que se publicó.
 *
 * Si la conexión se corta, el `.part` se queda y la próxima vez se pide solo
 * lo que falta (`Range`). En el almacén pasa: la terminal cambia de punto de
 * acceso a mitad de 60 MB (TC56, 2026-10-08, cortada en 26 MB tras once
 * minutos) y empezar de cero cada vez es no terminar nunca.
 *
 * Cuánto se espera sin que llegue un byte lo pone el `readTimeout` de [http]:
 * sin tope, una conexión colgada (la terminal cambió de red y el servidor ya
 * la cerró) deja la descarga «bajando» para siempre.
 */
internal class Descarga(
    private val http: OkHttpClient,
    private val carpeta: File,
    private val prefijo: String,
) {
    fun destino(v: VersionDisponible) = File(carpeta, "${prefijo}_${v.build}.apk")

    /** El APK de [v] si ya está bajado entero. */
    fun yaBajado(v: VersionDisponible): File? {
        val f = destino(v)
        if (!f.isFile) return null
        if (v.bytes > 0 && f.length() != v.bytes) return null
        return f
    }

    /** Lanza [IOException] si se corta o lo que llegó no cuadra. */
    fun bajar(v: VersionDisponible, progreso: (Double) -> Unit): File {
        yaBajado(v)?.let { return it }
        carpeta.mkdirs()
        val destino = destino(v)
        // La huella de la URL va en el nombre: un pedazo solo se retoma con el
        // MISMO archivo. Con otra URL sería pegarle el final de un APK al
        // principio de otro.
        val parcial = File(carpeta, "${destino.name}.${huella(v.url)}.part")
        var esperado = v.bytes
        var desde = if (parcial.isFile) parcial.length() else 0L
        if (esperado > 0 && desde > esperado) {
            parcial.delete()
            desde = 0
        }
        if (esperado <= 0 || desde < esperado) {
            val req = Request.Builder().url(v.url).apply {
                if (desde > 0) header("Range", "bytes=$desde-")
            }.build()
            http.newCall(req).execute().use { res ->
                var total: Long
                val agregar: Boolean
                when {
                    res.code == 206 && desde > 0 -> {
                        val rango = rango(res.header("Content-Range"))
                        if (rango == null || rango.first != desde) {
                            // Contestó otro pedazo del que se pidió: no se arriesga a pegarlo.
                            parcial.delete()
                            throw IOException("El servidor mandó otro pedazo")
                        }
                        total = rango.second
                        agregar = true
                    }
                    res.code == 200 -> {
                        // Sin `Range` (o el servidor no lo atiende): desde el principio.
                        desde = 0
                        total = res.body?.contentLength() ?: -1
                        agregar = false
                    }
                    else -> {
                        // 416: el pedazo no cuadra con el archivo. Cualquier otro
                        // (404, 410, 5xx) no dice nada del pedazo: se queda.
                        if (res.code == 416) parcial.delete()
                        throw IOException("HTTP ${res.code}")
                    }
                }
                if (total <= 0) total = esperado
                var recibido = desde
                if (total > 0) progreso(recibido.toDouble() / total)
                val cuerpo = res.body ?: throw IOException("Respuesta sin cuerpo")
                cuerpo.byteStream().use { entrada ->
                    FileOutputStream(parcial, agregar).use { salida ->
                        val buf = ByteArray(64 * 1024)
                        while (true) {
                            val n = entrada.read(buf)
                            if (n < 0) break
                            salida.write(buf, 0, n)
                            recibido += n
                            if (total > 0) progreso(recibido.toDouble() / total)
                        }
                        salida.fd.sync()
                    }
                }
                if (esperado <= 0) esperado = total
            }
        }
        val largo = parcial.length()
        if (esperado > 0 && largo != esperado) {
            // De más es un pedazo que no era: fuera. De menos, se sigue después.
            if (largo > esperado) parcial.delete()
            throw IOException("Llegaron $largo de $esperado bytes")
        }
        if (v.sha256.isNotEmpty()) {
            val sha = sha256(parcial)
            if (!sha.equals(v.sha256, ignoreCase = true)) {
                parcial.delete()
                throw IOException("El APK bajado no es el publicado (sha256 distinto)")
            }
        }
        if (destino.exists()) destino.delete()
        if (!parcial.renameTo(destino)) throw IOException("No se pudo guardar ${destino.name}")
        limpiar(conservar = destino.name)
        return destino
    }

    /**
     * Borra APK de otras versiones y pedazos huérfanos: cada uno pesa decenas
     * de MB y ya no sirve. Con [conservar] null, borra todos.
     */
    fun limpiar(conservar: String? = null) {
        carpeta.listFiles()?.forEach { f ->
            val n = f.name
            if (n == conservar) return@forEach
            if (!n.startsWith("${prefijo}_")) return@forEach
            if (!n.endsWith(".apk") && !n.endsWith(".part")) return@forEach
            f.delete()
        }
    }

    companion object {
        /** `bytes 100-199/1000` → (100, 1000). El total puede venir como `*` (→ -1). */
        fun rango(cabecera: String?): Pair<Long, Long>? {
            val m = Regex("""^bytes\s+(\d+)-(\d+)/(\d+|\*)$""").find(cabecera?.trim().orEmpty()) ?: return null
            return m.groupValues[1].toLong() to (m.groupValues[3].toLongOrNull() ?: -1L)
        }

        /** FNV-1a de 32 bits, en hexadecimal: corto y estable entre procesos. */
        fun huella(s: String): String {
            var h = 0x811c9dc5L
            for (b in s.toByteArray(Charsets.UTF_8)) {
                h = ((h xor (b.toLong() and 0xff)) * 0x01000193L) and 0xffffffffL
            }
            return h.toString(16).padStart(8, '0')
        }

        fun sha256(f: File): String {
            val md = MessageDigest.getInstance("SHA-256")
            f.inputStream().use { e ->
                val buf = ByteArray(64 * 1024)
                while (true) {
                    val n = e.read(buf)
                    if (n < 0) break
                    md.update(buf, 0, n)
                }
            }
            return md.digest().joinToString("") { "%02x".format(it) }
        }
    }
}
