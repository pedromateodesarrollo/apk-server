package com.chalonasoft.apkserver

import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.IOException

/** Una versión publicada más nueva que la instalada. */
data class VersionDisponible(
    /** Nombre de la versión (`1.14.0`). */
    val version: String,
    /** `versionCode`: es lo que se compara. */
    val build: Long,
    /** Alguna versión por encima de la instalada es obligatoria. */
    val requerido: Boolean,
    /** URL absoluta del APK. Lleva el sha256 en el nombre: no caduca. */
    val url: String,
    val notas: String = "",
    val sha256: String = "",
    val bytes: Long = 0,
) {
    companion object {
        /** Desde la respuesta de `/v1/apps/:app/consulta` (o `/ultima`). Null si no hay nada que bajar. */
        fun deRespuesta(r: JSONObject, hub: String): VersionDisponible? {
            if (!r.optBoolean("actualizar")) return null
            val v = r.optJSONObject("version") ?: return null
            val build = v.optLong("build", 0)
            val ruta = v.optString("url").ifEmpty { v.optString("ruta") }
            if (build <= 0 || ruta.isEmpty()) return null
            return VersionDisponible(
                version = v.optString("version").ifEmpty { "$build" },
                build = build,
                requerido = r.optBoolean("requerido"),
                url = if (ruta.startsWith("http")) ruta else "${hub.trimEnd('/')}$ruta",
                notas = v.optString("notas"),
                sha256 = v.optString("sha256"),
                bytes = v.optLong("bytes", 0),
            )
        }
    }
}

/**
 * `POST /v1/apps/:app/consulta`: «tengo la build N, ¿hay algo?». De paso el hub
 * anota el equipo (lo que va en [cuerpo]: build, clave de la instalación,
 * ANDROID_ID, modelo, contexto…), que es lo que se ve en la pestaña Equipos.
 */
internal class Consulta(private val http: OkHttpClient) {
    /** Lanza [IOException] si el hub no contesta bien. */
    fun preguntar(hub: String, app: String, cuerpo: JSONObject): VersionDisponible? {
        val base = hub.trimEnd('/')
        val req = Request.Builder()
            .url("$base/v1/apps/${app}/consulta")
            .post(cuerpo.toString().toRequestBody("application/json".toMediaType()))
            .build()
        http.newCall(req).execute().use { res ->
            val texto = res.body?.string().orEmpty()
            if (res.code != 200) throw IOException("El hub contestó ${res.code}: ${texto.take(200)}")
            val d = try {
                JSONObject(texto)
            } catch (e: Exception) {
                throw IOException("Respuesta inesperada del hub", e)
            }
            return VersionDisponible.deRespuesta(d, base)
        }
    }
}
