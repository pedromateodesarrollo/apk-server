package com.chalonasoft.apkserver

import okhttp3.OkHttpClient
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

class ActualizadorTest {
    private lateinit var hub: HubDePrueba
    private lateinit var carpeta: File
    private val hilo = Executors.newSingleThreadScheduledExecutor()
    private val io = Executors.newCachedThreadPool()
    private lateinit var p: Falsa
    private lateinit var ajustes: Ajustes
    private lateinit var a: Actualizador

    /** El teléfono de mentira. */
    inner class Falsa : Plataforma {
        var build = 80L
        var medido = false
        var sinPreguntar = true
        var ultimo = 0L
        var listoGuardado: Pair<VersionDisponible, File>? = null

        /** Lo que contesta Android al instalar; null = no contesta (instaló y cerró la app). */
        var respuesta: String? = "instalada"
        val instalaciones = CopyOnWriteArrayList<Boolean>()
        val estados = CopyOnWriteArrayList<Estado>()

        override fun hub() = hub.url
        override fun app() = "inventario"
        override fun buildActual() = build
        override fun instalacion() = "clave-de-prueba"
        override fun cuerpoConsulta(): JSONObject = JSONObject().put("build", build).put("instalacion", "clave-de-prueba")
        override fun medido() = medido
        override fun ultimoChequeo() = ultimo
        override fun guardarUltimoChequeo(ms: Long) {
            ultimo = ms
        }
        override fun guardarListo(v: VersionDisponible?, apk: File?) {
            listoGuardado = if (v != null && apk != null) v to apk else null
        }
        override fun sinPreguntar() = sinPreguntar
        override fun instalar(apk: File, version: String, conDialogo: Boolean, listo: (String) -> Unit) {
            instalaciones += conDialogo
            respuesta?.let { r -> io.execute { listo(r) } }
        }
        override fun alCambiar(e: Estado) {
            estados += e
        }
    }

    @Before
    fun antes() {
        hub = HubDePrueba()
        carpeta = Files.createTempDirectory("apk-server-prueba").toFile()
        p = Falsa()
        ajustes = Ajustes().apply { esperasReintentoMs = listOf(20L) }
        a = nuevo()
    }

    private fun nuevo(): Actualizador {
        val http = OkHttpClient.Builder().readTimeout(500, TimeUnit.MILLISECONDS).build()
        return Actualizador(ajustes, p, Consulta(http), Descarga(http, carpeta, "inventario"), hilo, io, null)
    }

    @After
    fun despues() {
        hilo.shutdownNow()
        io.shutdownNow()
        hub.close()
        carpeta.deleteRecursively()
    }

    /** Espera (hasta 5 s) a que el estado cumpla [cond]. */
    private fun esperar(cond: (Estado) -> Boolean): Estado {
        val hasta = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < hasta) {
            val e = hilo.submit<Estado> { a.estado }.get()
            if (cond(e)) return e
            Thread.sleep(10)
        }
        throw AssertionError("No llegó; está en ${a.estado}")
    }

    /** Deja que lo encolado en el hilo termine. */
    private fun calmar() {
        Thread.sleep(150)
        hilo.submit {}.get()
    }

    @Test
    fun `pregunta, baja y queda lista`() {
        a.verificar(forzar = true)
        val e = esperar { it.fase == Fase.LISTO }
        assertEquals("1.84.0", e.version)
        assertEquals(84L, e.build)
        assertTrue(File(e.apk!!).isFile)
        assertNull(e.falta)
        assertEquals(84L, p.listoGuardado?.first?.build)
        assertTrue(p.estados.any { it.fase == Fase.VERIFICANDO })
        assertTrue(p.estados.any { it.fase == Fase.DESCARGANDO })
    }

    @Test
    fun `al día no hace nada y respeta el freno`() {
        hub.build = 80
        var contestó = false
        a.verificar(forzar = true) { contestó = true }
        esperar { contestó && it.fase == Fase.AL_DIA }
        a.verificar(forzar = false)
        calmar()
        assertEquals("la segunda frenó", 1, hub.consultas.size)
    }

    @Test
    fun `sin decir que es a pedido, no pasa por verificando`() {
        hub.build = 80
        a.verificar(forzar = true, silencioso = true)
        calmar()
        assertTrue(p.estados.none { it.fase == Fase.VERIFICANDO })
    }

    @Test
    fun `una descarga cortada se reintenta sola hasta llegar`() {
        hub.cortes = 2
        a.verificar(forzar = true)
        val e = esperar { it.fase == Fase.LISTO }
        assertTrue(p.estados.any { it.fase == Fase.ERROR && it.version == "1.84.0" })
        assertEquals("bytes=100000-", hub.rangos[1])
        assertTrue(File(e.apk!!).readBytes().contentEquals(hub.apk))
    }

    @Test
    fun `si la versión deja de estar, deja de reintentar`() {
        hub.cortes = 1
        a.verificar(forzar = true)
        esperar { it.fase == Fase.ERROR }
        hub.build = 80 // se retiró
        esperar { it.fase == Fase.AL_DIA }
        val pedidas = hub.server.requestCount
        calmar()
        assertEquals(pedidas, hub.server.requestCount)
        assertTrue("sin pedazos huérfanos", carpeta.listFiles()!!.isEmpty())
    }

    @Test
    fun `sin red para preguntar, la versión sigue pendiente`() {
        hub.cortes = 1
        a.verificar(forzar = true)
        esperar { it.fase == Fase.ERROR }
        hub.consultaCaida = true
        Thread.sleep(200) // un par de reintentos que no llegan al hub
        val e = hilo.submit<Estado> { a.estado }.get()
        assertEquals(Fase.ERROR, e.fase)
        assertEquals("1.84.0", e.version)
        hub.consultaCaida = false
        esperar { it.fase == Fase.LISTO }
    }

    @Test
    fun `una versión retirada con el APK ya bajado deja de ofrecerse`() {
        a.verificar(forzar = true)
        val e = esperar { it.fase == Fase.LISTO }
        hub.build = 80
        a.verificar(forzar = true)
        esperar { it.fase == Fase.AL_DIA }
        assertFalse(File(e.apk!!).exists())
        assertNull(p.listoGuardado)
    }

    @Test
    fun `solo con Wi-Fi - espera y baja en cuanto deja de haber medidor`() {
        ajustes.soloWifi = true
        p.medido = true
        a.verificar(forzar = true)
        esperar { it.fase == Fase.ESPERANDO_WIFI }
        assertEquals(0, hub.rangos.size)
        p.medido = false
        a.alCambiarRed(otra = false)
        esperar { it.fase == Fase.LISTO }
    }

    @Test
    fun `solo con Wi-Fi - a pedido baja igual`() {
        ajustes.soloWifi = true
        p.medido = true
        a.verificar(forzar = true, manual = true)
        esperar { it.fase == Fase.LISTO }
    }

    @Test
    fun `instalar - Android pide confirmar y el APK sigue listo`() {
        p.respuesta = "confirmar"
        a.verificar(forzar = true)
        esperar { it.fase == Fase.LISTO }
        var r: String? = null
        a.instalar(conDialogo = false) { r = it }
        val e = esperar { r != null && it.fase == Fase.LISTO }
        assertEquals("confirmar", r)
        assertEquals("confirmar", e.falta)
        assertTrue(p.estados.any { it.fase == Fase.INSTALANDO })
    }

    @Test
    fun `instalar - dos toques seguidos arman una sola instalación`() {
        p.respuesta = null // instala y la app «se cierra»: Android no contesta
        a.verificar(forzar = true)
        esperar { it.fase == Fase.LISTO }
        val rs = CopyOnWriteArrayList<String>()
        a.instalar(conDialogo = true) { rs += it }
        a.instalar(conDialogo = true) { rs += it }
        calmar()
        assertEquals(1, p.instalaciones.size)
        assertEquals(listOf("en_curso"), rs)
        assertEquals(Fase.INSTALANDO, a.estado.fase)
    }

    @Test
    fun `instalar - sin diálogo y sin poder ir sin preguntar no hace nada`() {
        p.sinPreguntar = false
        a.verificar(forzar = true)
        val e = esperar { it.fase == Fase.LISTO }
        assertEquals("permiso", e.falta)
        var r: String? = null
        a.instalar(conDialogo = false) { r = it }
        calmar()
        assertEquals("hace_falta_dialogo", r)
        assertTrue(p.instalaciones.isEmpty())
    }

    @Test
    fun `instalar sin APK no hace nada`() {
        var r: String? = null
        a.instalar(conDialogo = true) { r = it }
        calmar()
        assertEquals("sin_apk", r)
    }

    @Test
    fun `autoInstalar - instala solo al terminar, una vez por versión`() {
        ajustes.autoInstalar = true
        p.respuesta = "error"
        a.verificar(forzar = true)
        esperar { it.fase == Fase.LISTO && p.instalaciones.size == 1 }
        assertEquals(listOf(false), p.instalaciones) // sin diálogo
        // Falló: queda listo y se puede volver a intentar.
        p.respuesta = null
        a.instalarSiListo()
        calmar()
        assertEquals(2, p.instalaciones.size)
        a.instalarSiListo()
        calmar()
        assertEquals("una vez por versión", 2, p.instalaciones.size)
    }

    @Test
    fun `autoInstalar - si la app no lo deja o haría falta preguntar, espera`() {
        ajustes.autoInstalar = true
        ajustes.puedeInstalar = { false }
        a.verificar(forzar = true)
        esperar { it.fase == Fase.LISTO }
        calmar()
        assertTrue(p.instalaciones.isEmpty())
        ajustes.puedeInstalar = { true }
        p.sinPreguntar = false
        a.instalarSiListo()
        calmar()
        assertTrue(p.instalaciones.isEmpty())
    }

    @Test
    fun `restaurar - lo que se bajó en otro proceso vuelve como listo`() {
        val v = hub.version()
        val apk = File(carpeta, "inventario_84.apk").apply { writeBytes(hub.apk) }
        a.restaurar(v, apk)
        val e = esperar { it.fase == Fase.LISTO }
        assertEquals(apk.path, e.apk)
        // Y si el hub sigue ofreciéndola, no se vuelve a bajar.
        a.verificar(forzar = true)
        calmar()
        assertTrue(hub.rangos.isEmpty())
    }

    @Test
    fun `restaurar - si ya se instaló, se borra`() {
        p.build = 84
        val apk = File(carpeta, "inventario_84.apk").apply { writeBytes(hub.apk) }
        p.listoGuardado = hub.version() to apk
        a.restaurar(hub.version(), apk)
        calmar()
        assertFalse(apk.exists())
        assertNull(p.listoGuardado)
        assertEquals(Fase.AL_DIA, a.estado.fase)
    }

    @Test
    fun `quizas - solo pregunta si pasó el intervalo`() {
        hub.build = 80
        p.ultimo = System.currentTimeMillis()
        a.quizas()
        calmar()
        assertEquals(0, hub.consultas.size)
        p.ultimo = System.currentTimeMillis() - ajustes.intervaloMs - 1
        a.quizas()
        calmar()
        assertEquals(1, hub.consultas.size)
    }

    @Test
    fun `sin hub configurado no pregunta nada`() {
        val sinHub = object : Plataforma by p {
            override fun hub() = ""
        }
        val http = OkHttpClient()
        a = Actualizador(ajustes, sinHub, Consulta(http), Descarga(http, carpeta, "x"), hilo, io, null)
        var contestó = false
        a.verificar(forzar = true) { contestó = true }
        calmar()
        assertTrue(contestó)
        assertEquals(0, hub.consultas.size)
    }
}
