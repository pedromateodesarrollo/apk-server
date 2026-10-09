package com.chalonasoft.apkserver

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import android.util.Log
import okhttp3.OkHttpClient
import org.json.JSONObject
import java.io.File
import java.security.SecureRandom
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * La actualización de la app, una por proceso.
 *
 * ```kotlin
 * // Application.onCreate (opcional: sin esto vale lo del manifiesto)
 * ApkServer.configurar(this) {
 *     soloWifi = true
 *     autoInstalar = true
 *     contexto = { JSONObject().put("usuario", sesion.nombre) }
 * }
 * // Donde la app quiera estar al día (su servicio, su pantalla principal):
 * ApkServer.de(this).iniciar()
 * ```
 *
 * El hub y el slug salen del manifiesto, que los pone la app en su
 * `build.gradle.kts` (`manifestPlaceholders["apkServerHub"]` y
 * `["apkServerApp"]`). El mismo dato le dice a `apk-publicar` a dónde subir
 * el APK: la app y su publicación no pueden decir cosas distintas.
 */
object ApkServer {
    private const val TAG = "apk_server"

    // Guarda el contexto de la aplicación, no el de una pantalla: no se fuga nada.
    @SuppressLint("StaticFieldLeak")
    @Volatile
    private var instancia: Actualizacion? = null

    /** La actualización de esta app. Se crea la primera vez, con lo del manifiesto. */
    @JvmStatic
    fun de(context: Context): Actualizacion =
        instancia ?: synchronized(this) {
            instancia ?: Actualizacion(context.applicationContext).also { instancia = it }
        }

    /**
     * Cambia los [Ajustes]. Lo mejor es antes de [Actualizacion.iniciar] (en
     * `Application.onCreate`): el hub, el slug, los avisos y lo de instalar se
     * leen en cada uso; el ping y las esperas del socket, al conectar.
     */
    @JvmStatic
    fun configurar(context: Context, cambios: Ajustes.() -> Unit): Actualizacion =
        de(context).also { it.ajustes.cambios() }

    /** Dónde se bajan los APK. */
    internal fun carpeta(ctx: Context) = File(ctx.cacheDir, "apk-server")

    /**
     * Al arrancar el proceso (desde [ApkProvider], antes que la app): si el
     * APK que estaba listo ya se instaló, se borra con su notificación. Si no,
     * la actualización recuerda que lo tiene.
     */
    internal fun alArrancar(ctx: Context) {
        try {
            de(ctx).restaurar()
        } catch (e: Exception) {
            Log.w(TAG, "Al arrancar", e)
        }
    }
}

/**
 * La actualización de la app. Se pide con [ApkServer.de]. Los métodos se
 * pueden llamar desde cualquier hilo; los oyentes y los `listo` corren en el
 * principal.
 */
class Actualizacion internal constructor(private val ctx: Context) {
    val ajustes = Ajustes()

    private val prefs: SharedPreferences = ctx.getSharedPreferences("apk_server", Context.MODE_PRIVATE)
    private val principal = Handler(Looper.getMainLooper())
    private val oyentes = CopyOnWriteArrayList<(Estado) -> Unit>()

    private val hilo = Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "apk-server") }
    private val io = Executors.newCachedThreadPool { r -> Thread(r, "apk-server-io").apply { isDaemon = true } }

    private val manifiesto: Pair<String, String> by lazy { leerManifiesto() }

    /** El hub de esta app (los ajustes, o el manifiesto). Vacío = no se actualiza. */
    val hub: String get() = ajustes.hub.ifBlank { manifiesto.first }.trim().trimEnd('/')

    /** El slug de esta app en el hub. */
    val app: String get() = ajustes.app.ifBlank { manifiesto.second }.trim()

    /** La página para instalarla en un equipo nuevo (`<hub>/i/<app>`), o null sin hub. */
    val urlInstalar: String? get() = if (hub.isEmpty() || app.isEmpty()) null else "$hub/i/$app"

    /** Clave de esta instalación: va en cada consulta y en el socket. */
    val instalacion: String by lazy { clave() }

    private val nucleo: Actualizador by lazy { crear() }

    /** La foto de ahora. */
    val estado: Estado get() = nucleo.estado

    /** ¿El socket de avisos está abierto? */
    val conectado: Boolean get() = nucleo.conectado

    /** Cada cambio de estado, en el hilo principal. Devuelve con qué dejar de escuchar. */
    fun escuchar(oyente: (Estado) -> Unit): () -> Unit {
        oyentes += oyente
        return { oyentes -= oyente }
    }

    /** Pregunta ya, cada hora y —con [Ajustes.avisos]— en cuanto el hub avise. Idempotente. */
    fun iniciar() {
        nucleo.iniciar()
        vigilarRed()
    }

    /** Para el sondeo, cierra el socket y deja de reintentar. */
    fun detener() {
        nucleo.detener()
        dejarDeVigilarRed()
    }

    /** Pregunta si pasó [Ajustes.intervaloMs] desde la última vez. Para el servicio de una app de fondo. */
    fun quizas() = nucleo.quizas()

    /**
     * Pregunta (con freno, salvo [forzar]) y baja si hay versión. [manual]:
     * lo pidió la persona, baja aunque la red tenga medidor. [silencioso]: no
     * pasa por «verificando» ni dice que falló. [listo] corre cuando el hub
     * contestó.
     */
    @JvmOverloads
    fun verificar(
        forzar: Boolean = false,
        manual: Boolean = false,
        silencioso: Boolean = false,
        listo: (() -> Unit)? = null,
    ) = nucleo.verificar(forzar, manual, silencioso, listo?.let { l -> { principal.post(l) } })

    /** La app volvió al frente: reconecta el socket, sigue la descarga cortada y pregunta. */
    fun alVolverAlFrente() = nucleo.alVolverAlFrente()

    /**
     * Instala el APK bajado: sin preguntar si Android lo deja (la app se
     * cierra); si no, con [conDialogo] y la app al frente, con la pantalla
     * del sistema. [listo] recibe `instalada | dialogo | confirmar | permiso |
     * no_soportado | error | sin_respuesta | sin_apk | en_curso |
     * hace_falta_dialogo`.
     */
    @JvmOverloads
    fun instalar(conDialogo: Boolean = true, listo: ((String) -> Unit)? = null) =
        nucleo.instalar(conDialogo, listo?.let { l -> { r: String -> principal.post { l(r) } } })

    /**
     * Con [Ajustes.autoInstalar]: si hay un APK listo y ya se puede sin
     * preguntar, instala (una vez por versión). Para después de que la persona
     * dio «Permitir de esta fuente».
     */
    fun instalarSiListo() = nucleo.instalarSiListo()

    /** ¿Instalar ahora iría sin preguntar? (Android 12+ y «Permitir de esta fuente») */
    fun sinPreguntar(): Boolean = Instalador.sinPreguntar(ctx)

    /** Lo que el equipo cuenta de sí en cada consulta. */
    @SuppressLint("HardwareIds")
    fun equipo(): Map<String, Any?> = mapOf(
        // El ANDROID_ID: sobrevive a desinstalar y reinstalar la app y es el
        // mismo para todas las apps firmadas con la misma llave en ese equipo.
        // Cambia con un reseteo de fábrica. No pide permiso.
        "huella" to Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ANDROID_ID),
        "modelo" to Build.MODEL,
        "fabricante" to Build.MANUFACTURER,
        "android" to Build.VERSION.SDK_INT,
    )

    // ------------------------------------------------------------ interno

    private fun crear(): Actualizador {
        val http = OkHttpClient.Builder()
            .connectTimeout(20, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
        val descargas = http.newBuilder().readTimeout(ajustes.sinDatosMs, TimeUnit.MILLISECONDS).build()
        val carpeta = ApkServer.carpeta(ctx)
        limpiarLegado(carpeta)
        return Actualizador(
            ajustes = ajustes,
            plataforma = plataforma,
            consulta = Consulta(http),
            descarga = Descarga(descargas, carpeta, prefijo()),
            hilo = hilo,
            io = io,
            avisosDe = { alConectar, alAviso ->
                Avisos(
                    httpDe = { http.newBuilder().pingInterval(ajustes.pingSegundos, TimeUnit.SECONDS).build() },
                    hilo = hilo,
                    esperaMinMs = 1_000L,
                    esperaMaxMs = { ajustes.esperaMaxAvisosMs },
                    alConectar = alConectar,
                    alAviso = alAviso,
                )
            },
        )
    }

    /** El nombre de los archivos bajados: el slug, o el paquete si no hay. */
    private fun prefijo() = app.ifEmpty { ctx.packageName }.replace(Regex("[^A-Za-z0-9._-]"), "_")

    /** Lo de [ApkServer.alArrancar]. */
    internal fun restaurar() {
        val build = prefs.getLong("listo_build", 0)
        if (build <= 0) return
        val apk = File(prefs.getString("listo_apk", "").orEmpty())
        if (build <= buildActual() || !apk.isFile) {
            // Ya se instaló (o se borró la caché): fuera el APK y su aviso.
            apk.delete()
            guardarListo(null, null)
            Notificaciones.quitar(ctx)
            return
        }
        val v = VersionDisponible(
            version = prefs.getString("listo_version", "").orEmpty().ifEmpty { "$build" },
            build = build,
            requerido = prefs.getBoolean("listo_requerido", false),
            url = prefs.getString("listo_url", "").orEmpty(),
            sha256 = prefs.getString("listo_sha256", "").orEmpty(),
            bytes = prefs.getLong("listo_bytes", 0),
        )
        nucleo.restaurar(v, apk)
    }

    private fun guardarListo(v: VersionDisponible?, apk: File?) {
        val e = prefs.edit()
        if (v == null || apk == null) {
            listOf("listo_build", "listo_version", "listo_requerido", "listo_url", "listo_sha256", "listo_bytes", "listo_apk")
                .forEach { e.remove(it) }
        } else {
            e.putLong("listo_build", v.build)
                .putString("listo_version", v.version)
                .putBoolean("listo_requerido", v.requerido)
                .putString("listo_url", v.url)
                .putString("listo_sha256", v.sha256)
                .putLong("listo_bytes", v.bytes)
                .putString("listo_apk", apk.path)
        }
        e.apply()
    }

    private fun buildActual(): Long {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        return if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
    }

    private fun leerManifiesto(): Pair<String, String> = try {
        val m = ctx.packageManager.getApplicationInfo(ctx.packageName, PackageManager.GET_META_DATA).metaData
        (m?.getString("com.chalonasoft.apkserver.HUB").orEmpty()) to (m?.getString("com.chalonasoft.apkserver.APP").orEmpty())
    } catch (e: Exception) {
        Log.w("apk_server", "No se pudo leer el manifiesto", e)
        "" to ""
    }

    /**
     * La clave de esta instalación. Se genera una vez; si la app ya tenía una
     * de su actualizador anterior, se usa esa: para el panel es el mismo
     * equipo.
     */
    private fun clave(): String {
        prefs.getString("instalacion", null)?.takeIf { it.length >= 8 }?.let { return it }
        val anterior = runCatching {
            // apk_server_flutter 0.1 (getApplicationSupportDirectory = filesDir).
            File(ctx.filesDir, "apk_server_instalacion").takeIf { it.isFile }?.readText()?.trim()
        }.getOrNull()?.takeIf { it.length >= 8 }
            // Los actualizadores nativos de trackme y del agente de device-track.
            ?: ctx.getSharedPreferences("actualizacion", Context.MODE_PRIVATE).getString("instalacion", null)
                ?.takeIf { it.length >= 8 }
        val c = anterior ?: ByteArray(16).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
        prefs.edit().putString("instalacion", c).apply()
        return c
    }

    /** Lo que dejaron los actualizadores de antes en la caché: APK de decenas de MB. */
    private fun limpiarLegado(carpeta: File) {
        if (prefs.getBoolean("legado_limpio", false)) return
        runCatching {
            val p = "${prefijo()}_"
            ctx.cacheDir.listFiles()?.forEach { f ->
                if (f.isFile && f.name.startsWith(p) && (f.name.endsWith(".apk") || f.name.endsWith(".part"))) f.delete()
            }
            File(ctx.cacheDir, "actualizacion").takeIf { it.isDirectory && it != carpeta }?.deleteRecursively()
        }
        prefs.edit().putBoolean("legado_limpio", true).apply()
    }

    private fun cuerpoConsulta(): JSONObject {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        val cuerpo = JSONObject()
            .put("build", buildActual())
            .put("version", info.versionName ?: "")
            .put("instalacion", instalacion)
        for ((k, v) in equipo()) if (v != null) cuerpo.put(k, v)
        // Lo que la app cuenta; si no dice nada (o falla), lo último que contó.
        val nuevo = runCatching { ajustes.contexto?.invoke() }
            .onFailure { Log.w("apk_server", "contexto", it) }
            .getOrNull()
        val contexto = if (nuevo != null) {
            prefs.edit().putString("contexto", nuevo.toString()).apply()
            nuevo
        } else {
            prefs.getString("contexto", null)?.let { runCatching { JSONObject(it) }.getOrNull() }
        }
        if (contexto != null) cuerpo.put("contexto", contexto)
        return cuerpo
    }

    private fun despierto(trabajo: () -> Unit) {
        val wl = if (ctx.checkPermission(Manifest.permission.WAKE_LOCK, Process.myPid(), Process.myUid()) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            (ctx.getSystemService(Context.POWER_SERVICE) as PowerManager)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "apkserver:actualizar")
                .apply {
                    setReferenceCounted(false)
                    acquire(15 * 60_000L)
                }
        } else {
            null
        }
        try {
            trabajo()
        } finally {
            if (wl?.isHeld == true) wl.release()
        }
    }

    private fun conectividad() = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    private var red: ConnectivityManager.NetworkCallback? = null

    /**
     * Si la red cambia (Wi-Fi ↔ datos), el socket se rehace; si vuelve, la
     * descarga cortada sigue ya; si aparece una sin medidor, la que esperaba
     * Wi-Fi arranca.
     */
    private fun vigilarRed(): Unit = synchronized(this) {
        if (red != null || Build.VERSION.SDK_INT < 24) return
        val cb = object : ConnectivityManager.NetworkCallback() {
            private var actual: Network? = null
            private var sinMedidor = false

            override fun onAvailable(network: Network) {
                val otra = actual != null && actual != network
                actual = network
                nucleo.alCambiarRed(otra)
            }

            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) {
                val ahora = caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_METERED)
                if (ahora && !sinMedidor) nucleo.alCambiarRed(false)
                sinMedidor = ahora
            }
        }
        try {
            conectividad().registerDefaultNetworkCallback(cb)
            red = cb
        } catch (e: Exception) {
            Log.w("apk_server", "Sin aviso de cambios de red", e)
        }
    }

    private fun dejarDeVigilarRed(): Unit = synchronized(this) {
        val cb = red ?: return
        red = null
        runCatching { conectividad().unregisterNetworkCallback(cb) }
    }

    private val plataforma = object : Plataforma {
        override fun hub() = this@Actualizacion.hub
        override fun app() = this@Actualizacion.app
        override fun buildActual() = this@Actualizacion.buildActual()
        override fun instalacion() = this@Actualizacion.instalacion
        override fun cuerpoConsulta() = this@Actualizacion.cuerpoConsulta()
        override fun medido() = runCatching { conectividad().isActiveNetworkMetered }.getOrDefault(false)
        override fun ultimoChequeo() = prefs.getLong("ultimo_chequeo", 0)
        override fun guardarUltimoChequeo(ms: Long) = prefs.edit().putLong("ultimo_chequeo", ms).apply()
        override fun guardarListo(v: VersionDisponible?, apk: File?) = this@Actualizacion.guardarListo(v, apk)
        override fun despierto(trabajo: () -> Unit) = this@Actualizacion.despierto(trabajo)
        override fun sinPreguntar() = Instalador.sinPreguntar(ctx)
        override fun instalar(apk: File, version: String, conDialogo: Boolean, listo: (String) -> Unit) =
            Instalador.instalar(ctx, apk, conDialogo, listo)

        override fun alCambiar(e: Estado) {
            runCatching { Notificaciones.mostrar(ctx, ajustes, e) }
            principal.post { for (o in oyentes) runCatching { o(e) }.onFailure { Log.w("apk_server", "oyente", it) } }
        }
    }
}
