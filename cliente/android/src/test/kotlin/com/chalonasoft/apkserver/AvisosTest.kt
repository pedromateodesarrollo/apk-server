package com.chalonasoft.apkserver

import okhttp3.OkHttpClient
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.util.concurrent.Executors
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class AvisosTest {
    private val server = MockWebServer()
    private val hilo = Executors.newSingleThreadScheduledExecutor()
    private val conexiones = AtomicInteger()
    private val avisos = AtomicInteger()

    /** Los sockets que abrió el cliente, del lado del hub. */
    private val delHub = LinkedBlockingQueue<WebSocket>()

    private fun aceptar() = server.enqueue(
        MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onOpen(webSocket: WebSocket, response: Response) {
                delHub.put(webSocket)
            }
        }),
    )

    private lateinit var ws: Avisos

    @Before
    fun antes() {
        server.start()
        ws = Avisos(
            httpDe = { OkHttpClient() },
            hilo = hilo,
            esperaMinMs = 20,
            esperaMaxMs = { 100 },
            alConectar = { conexiones.incrementAndGet() },
            alAviso = { avisos.incrementAndGet() },
        )
    }

    @After
    fun despues() {
        hilo.submit { ws.cerrar() }.get()
        hilo.shutdownNow()
        runCatching { server.shutdown() } // con el socket del hub todavía abierto tarda en soltarlo
    }

    private fun hasta(cond: () -> Boolean) {
        val fin = System.currentTimeMillis() + 5_000
        while (!cond()) {
            if (System.currentTimeMillis() > fin) throw AssertionError("No llegó")
            Thread.sleep(10)
        }
    }

    @Test
    fun `conecta con la app y la clave, y un aviso de esta app hace preguntar`() {
        aceptar()
        hilo.execute { ws.conectar(server.url("/").toString(), "inventario", "clave123") }
        val hubWs = delHub.poll(5, TimeUnit.SECONDS)!!
        hasta { conexiones.get() == 1 }
        val pedido = server.takeRequest()
        assertEquals("/v1/ws?app=inventario&instalacion=clave123", pedido.path)
        assertTrue(hilo.submit<Boolean> { ws.conectado }.get())

        hubWs.send("""{"tipo":"version","app":"otra","build":9}""")
        hubWs.send("""{"tipo":"ping"}""")
        hubWs.send("""{"tipo":"version","app":"inventario","build":85}""")
        hasta { avisos.get() == 1 }
        Thread.sleep(100)
        assertEquals("solo el de esta app", 1, avisos.get())
    }

    @Test
    fun `si el hub cierra, reconecta solo y vuelve a preguntar`() {
        aceptar()
        aceptar()
        hilo.execute { ws.conectar(server.url("/").toString(), "inventario", "clave123") }
        delHub.poll(5, TimeUnit.SECONDS)!!.close(1001, "reinicio")
        delHub.poll(5, TimeUnit.SECONDS)!!
        hasta { conexiones.get() == 2 }
    }

    @Test
    fun `urlDe arma el socket desde el hub`() {
        assertEquals(
            "wss://apk.ejemplo.com/v1/ws?app=wms&instalacion=abc",
            Avisos.urlDe("https://apk.ejemplo.com/", "wms", "abc")!!.replace("https://", "wss://"),
        )
    }
}
