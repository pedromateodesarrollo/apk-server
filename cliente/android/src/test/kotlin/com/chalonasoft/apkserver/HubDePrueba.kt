package com.chalonasoft.apkserver

import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit

/**
 * Un hub de mentira: contesta la consulta y sirve el APK, con `Range`, y se
 * le puede pedir que corte la descarga a mitad, que la deje colgada o que
 * no atienda `Range`.
 */
class HubDePrueba : AutoCloseable {
    val server = MockWebServer()

    /** El «APK»: bytes cualesquiera, lo que importa es que lleguen todos y en orden. */
    var apk: ByteArray = ByteArray(300_000) { (it * 31 % 251).toByte() }

    /** Build publicada; 0 = no hay nada que bajar. */
    @Volatile
    var build: Long = 84

    @Volatile
    var requerido = false

    /** La consulta contesta 500 (el hub no está). */
    @Volatile
    var consultaCaida = false

    /** Las próximas N descargas se cortan tras [cortarEn] bytes. */
    @Volatile
    var cortes = 0

    @Volatile
    var cortarEn = 100_000

    /** La próxima descarga se queda colgada (no manda nada). */
    @Volatile
    var colgar = false

    /** No atiende `Range`: siempre manda el archivo entero. */
    @Volatile
    var sinRange = false

    val consultas = CopyOnWriteArrayList<JSONObject>()
    val rangos = CopyOnWriteArrayList<String?>()

    val url: String get() = server.url("/").toString().trimEnd('/')
    val sha256: String
        get() = MessageDigest.getInstance("SHA-256").digest(apk).joinToString("") { "%02x".format(it) }

    fun version() = VersionDisponible(
        version = "1.$build.0",
        build = build,
        requerido = requerido,
        url = "$url/archivos/$sha256.apk",
        sha256 = sha256,
        bytes = apk.size.toLong(),
    )

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val ruta = request.path.orEmpty()
                return when {
                    ruta.contains("/consulta") -> consulta(request)
                    ruta.startsWith("/archivos/") -> archivo(request)
                    else -> MockResponse().setResponseCode(404)
                }
            }
        }
        server.start()
    }

    private fun consulta(r: RecordedRequest): MockResponse {
        consultas += JSONObject(r.body.readUtf8())
        if (consultaCaida) return MockResponse().setResponseCode(500).setBody("caído")
        val d = JSONObject().put("build_actual", consultas.last().optLong("build"))
        if (build <= consultas.last().optLong("build")) {
            d.put("actualizar", false).put("requerido", false)
        } else {
            val v = version()
            d.put("actualizar", true).put("requerido", requerido).put(
                "version",
                JSONObject().put("build", v.build).put("version", v.version).put("sha256", v.sha256)
                    .put("bytes", v.bytes).put("ruta", "/archivos/${v.sha256}.apk"),
            )
        }
        return MockResponse().setHeader("Content-Type", "application/json").setBody(d.toString())
    }

    private fun archivo(r: RecordedRequest): MockResponse {
        val rango = r.getHeader("Range")
        rangos += rango
        if (colgar) {
            colgar = false
            return MockResponse()
                .setHeader("Content-Length", apk.size)
                .setBody(Buffer().write(apk))
                .throttleBody(1, 10, TimeUnit.SECONDS)
        }
        var desde = 0
        if (rango != null && !sinRange) {
            desde = Regex("""bytes=(\d+)-""").find(rango)!!.groupValues[1].toInt()
        }
        val resto = apk.copyOfRange(desde, apk.size)
        val res = if (desde > 0) {
            MockResponse().setResponseCode(206)
                .setHeader("Content-Range", "bytes $desde-${apk.size - 1}/${apk.size}")
        } else {
            MockResponse().setResponseCode(200)
        }
        if (cortes > 0) {
            cortes--
            val n = minOf(cortarEn, resto.size)
            return res.setBody(Buffer().write(resto, 0, n))
                .setHeader("Content-Length", resto.size)
                .setSocketPolicy(SocketPolicy.DISCONNECT_AT_END)
        }
        return res.setBody(Buffer().write(resto))
    }

    // La descarga colgada a propósito sigue «mandando» un byte cada 10 s: no se espera.
    override fun close() {
        runCatching { server.shutdown() }
    }
}
