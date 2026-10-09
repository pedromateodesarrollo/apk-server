package com.chalonasoft.apkserver

import okhttp3.OkHttpClient
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.util.concurrent.TimeUnit

class DescargaTest {
    private lateinit var hub: HubDePrueba
    private lateinit var carpeta: File
    private lateinit var descarga: Descarga

    @Before
    fun antes() {
        hub = HubDePrueba()
        carpeta = Files.createTempDirectory("apk-server-prueba").toFile()
        val http = OkHttpClient.Builder().readTimeout(500, TimeUnit.MILLISECONDS).build()
        descarga = Descarga(http, carpeta, "inventario")
    }

    @After
    fun despues() {
        hub.close()
        carpeta.deleteRecursively()
    }

    private fun partes() = carpeta.listFiles()!!.filter { it.name.endsWith(".part") }

    private fun bajarYFallar(v: VersionDisponible) {
        try {
            descarga.bajar(v) {}
            fail("tenía que cortarse")
        } catch (_: IOException) {
        }
    }

    @Test
    fun `se corta a mitad - queda el pedazo y la siguiente sigue desde ahí`() {
        hub.cortes = 1
        val v = hub.version()
        bajarYFallar(v)
        assertEquals(1, partes().size)
        assertEquals(100_000L, partes()[0].length())
        assertNull(descarga.yaBajado(v))

        val progreso = mutableListOf<Double>()
        val apk = descarga.bajar(v) { progreso += it }
        assertArrayEquals(hub.apk, apk.readBytes())
        assertEquals("bytes=100000-", hub.rangos.last())
        assertTrue("la barra no vuelve a cero", progreso.first() >= 0.33)
        assertEquals(1.0, progreso.last(), 0.0)
        assertTrue(partes().isEmpty())
        assertEquals("inventario_84.apk", apk.name)
    }

    @Test
    fun `conexión colgada - se da por cortada y después sigue`() {
        hub.colgar = true
        val v = hub.version()
        bajarYFallar(v)
        val apk = descarga.bajar(v) {}
        assertArrayEquals(hub.apk, apk.readBytes())
    }

    @Test
    fun `si el servidor no atiende Range, empieza de cero y queda bien`() {
        hub.cortes = 1
        hub.sinRange = true
        val v = hub.version()
        bajarYFallar(v)
        val apk = descarga.bajar(v) {}
        assertArrayEquals(hub.apk, apk.readBytes())
    }

    @Test
    fun `un pedazo de otra URL no se pega`() {
        hub.cortes = 1
        val v = hub.version()
        bajarYFallar(v)
        // Misma build, otro archivo (se volvió a publicar con otro contenido).
        hub.apk = ByteArray(250_000) { (it * 7 % 13).toByte() }
        val otra = hub.version()
        val apk = descarga.bajar(otra) {}
        assertArrayEquals(hub.apk, apk.readBytes())
        assertNull("la segunda empezó de cero", hub.rangos.last())
    }

    @Test
    fun `con otro tamaño que el dicho, no se da por bajada`() {
        val v = hub.version().copy(bytes = hub.apk.size + 10L, sha256 = "")
        bajarYFallar(v)
        assertFalse(File(carpeta, "inventario_84.apk").exists())
    }

    @Test
    fun `si el sha256 no cuadra, se borra y no se da por bajada`() {
        val v = hub.version().copy(sha256 = "00".repeat(32))
        bajarYFallar(v)
        assertFalse(File(carpeta, "inventario_84.apk").exists())
        assertTrue(partes().isEmpty())
    }

    @Test
    fun `al terminar borra los APK de otras versiones`() {
        File(carpeta, "inventario_80.apk").writeText("viejo")
        File(carpeta, "inventario_81.apk.12345678.part").writeText("pedazo")
        File(carpeta, "otra_80.apk").writeText("de otra app")
        descarga.bajar(hub.version()) {}
        assertEquals(setOf("inventario_84.apk", "otra_80.apk"), carpeta.list()!!.toSet())
    }

    @Test
    fun `lo ya bajado se reusa sin pedir nada`() {
        val v = hub.version()
        descarga.bajar(v) {}
        val pedidas = hub.server.requestCount
        descarga.bajar(v) {}
        assertEquals(pedidas, hub.server.requestCount)
    }

    @Test
    fun `rango y huella`() {
        assertEquals(100L to 1000L, Descarga.rango("bytes 100-199/1000"))
        assertEquals(5L to -1L, Descarga.rango("bytes 5-9/*"))
        assertNull(Descarga.rango("basura"))
        // La misma huella que calculaba el plugin de Dart (FNV-1a de 32 bits).
        assertEquals("1a47e90b", Descarga.huella("abc"))
        assertEquals(8, Descarga.huella("https://hub/archivos/x.apk").length)
    }
}
