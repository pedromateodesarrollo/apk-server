package com.chalonasoft.apkserver

import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit

/**
 * Lo que el [Actualizador] necesita del teléfono. En la app lo da [ApkServer];
 * en las pruebas, uno de mentira.
 */
internal interface Plataforma {
    /** Hub y slug de la app; vacíos = no se actualiza. Se leen en cada uso: pueden cambiar. */
    fun hub(): String
    fun app(): String

    fun buildActual(): Long

    /** Clave de esta instalación (se genera una vez y se guarda). */
    fun instalacion(): String

    /** Lo que va en cada consulta: build, clave, equipo y contexto. Corre fuera del hilo del actualizador. */
    fun cuerpoConsulta(): JSONObject

    /** ¿La red tiene medidor (datos móviles)? */
    fun medido(): Boolean

    fun ahora(): Long = System.currentTimeMillis()
    fun ultimoChequeo(): Long
    fun guardarUltimoChequeo(ms: Long)

    /** El APK bajado y no instalado, para recordarlo si el proceso se reinicia. */
    fun guardarListo(v: VersionDisponible?, apk: File?)

    /** Cuándo se instala lo bajado (cuenta regresiva del aviso); 0 = sin aviso. Sobrevive al proceso. */
    fun guardarInstalaEn(ms: Long) = Unit

    /** ¿Se puede abrir una pantalla del sistema (el instalador) ahora? Antes de Android 10, siempre. */
    fun puedeAbrirPantalla(): Boolean = false

    /** Corre [trabajo] sin que el teléfono se duerma (wakelock), si se puede. */
    fun despierto(trabajo: () -> Unit) = trabajo()

    /** ¿Instalar ahora iría sin preguntar? */
    fun sinPreguntar(): Boolean

    /**
     * Arranca la instalación. [listo] recibe `instalada | dialogo | confirmar |
     * permiso | no_soportado | error | sin_respuesta`; con `instalada`, casi
     * nunca: Android cierra la app antes.
     */
    fun instalar(apk: File, version: String, conDialogo: Boolean, listo: (String) -> Unit)

    /** Cada cambio de estado (desde el hilo del actualizador). */
    fun alCambiar(e: Estado)
}

/**
 * Decide cuándo preguntar, bajar, reintentar e instalar. Es la misma lógica
 * para cualquier app: la de Flutter, una nativa con un servicio en segundo
 * plano o una que solo se abre de vez en cuando.
 *
 * Todo pasa por [hilo] (un solo hilo): no hay dos decisiones a la vez. Lo que
 * bloquea —la consulta, la descarga— corre en [io] y vuelve a [hilo] con el
 * resultado.
 *
 * Caminos para enterarse de una versión, todos desembocan en [verificar]:
 *  - el sondeo de respaldo, cada [Ajustes.intervaloMs] ([iniciar]);
 *  - el aviso del WebSocket (y cada reconexión);
 *  - la app: al volver al frente, tras cada tarea de su servicio ([quizas]),
 *    un botón.
 *
 * Una descarga que se corta no se abandona: queda [pendiente] y se reintenta
 * con [Ajustes.esperasReintentoMs], o ya en cuanto vuelve la red.
 */
internal class Actualizador(
    private val ajustes: Ajustes,
    private val plataforma: Plataforma,
    private val consulta: Consulta,
    private val descarga: Descarga,
    private val hilo: ScheduledExecutorService,
    private val io: Executor,
    /** El socket de avisos; null en las pruebas que no lo usan. Se abre solo con [Ajustes.avisos]. */
    avisosDe: ((alConectar: () -> Unit, alAviso: () -> Unit) -> Avisos)?,
) {
    /** Se escribe en [hilo] y se lee desde cualquiera (la app, el plugin). */
    @Volatile
    var estado = Estado()
        private set

    private val avisos: Avisos? = avisosDe?.invoke(
        { reintentarYa(); verificarAhora(forzar = true, silencioso = true) },
        { verificarAhora(forzar = true, silencioso = true) },
    )

    /** ¿El socket de avisos está abierto? (el panel ve el equipo conectado) */
    val conectado: Boolean get() = avisos?.conectado == true

    /** La última versión que dijo el hub; null si al día o sin preguntar todavía. */
    private var ultima: VersionDisponible? = null

    /** El APK completo y su versión. */
    private var listo: Pair<VersionDisponible, File>? = null

    /**
     * La versión que se está bajando y todavía no llegó entera. Un corte no la
     * suelta: queda aquí hasta que se baja, el hub dice que ya no hay nada o
     * sale otra.
     */
    private var pendiente: VersionDisponible? = null
    private var pendienteManual = false
    private var bajando: VersionDisponible? = null
    private var reintento: ScheduledFuture<*>? = null
    private var fallos = 0

    private var consultando = false
    private val alTerminarConsulta = mutableListOf<() -> Unit>()

    private var sondeo: ScheduledFuture<*>? = null
    private var instalando = false
    private var autoLanzada: Long = -1

    /** Con aviso: cuándo se instala lo que está [listo] (epoch ms); 0 = sin cuenta regresiva. */
    private var instalaEn: Long = 0
    private var avisoTarea: ScheduledFuture<*>? = null

    /** Venció el aviso con la app detrás y Android pedía a la persona: al volver al frente, el instalador. */
    private var instalarAlFrente = false

    // ------------------------------------------------------------ entrada

    /**
     * Recupera un APK que ya estaba bajado de otra vez que corrió la app. Con
     * [instalaEnGuardado] (había cuenta regresiva) el aviso sigue; si su hora
     * pasó con la app cerrada, se da un minuto más de aviso: nunca sin avisar.
     */
    fun restaurar(v: VersionDisponible, apk: File, instalaEnGuardado: Long = 0) = hilo.execute {
        if (listo != null || bajando != null) return@execute
        if (v.build <= plataforma.buildActual() || !apk.isFile) {
            // Ya se instaló (o se borró): fuera.
            apk.delete()
            plataforma.guardarListo(null, null)
            plataforma.guardarInstalaEn(0)
            return@execute
        }
        listo = v to apk
        ultima = v
        if (instalaEnGuardado > 0) {
            avisar(maxOf(instalaEnGuardado, plataforma.ahora() + ULTIMO_AVISO_MS))
        }
        cambiar(listoDe(v, apk))
    }

    /** Sondeo cada [Ajustes.intervaloMs], socket si [Ajustes.avisos], y pregunta ya. Idempotente. */
    fun iniciar() = hilo.execute {
        if (!configurado()) return@execute
        sondeo?.cancel(false)
        val cada = ajustes.intervaloMs
        sondeo = hilo.scheduleWithFixedDelay(
            { verificarAhora(forzar = false, silencioso = true) }, cada, cada, TimeUnit.MILLISECONDS,
        )
        if (ajustes.avisos) {
            avisos?.conectar(plataforma.hub(), plataforma.app(), plataforma.instalacion())
        } else {
            avisos?.cerrar()
        }
        verificarAhora(forzar = false, silencioso = true)
        if (pendiente != null && reintento == null && bajando == null) programarReintento()
    }

    /** Para el sondeo, cierra el socket y deja de reintentar. La descarga en vuelo termina. */
    fun detener() = hilo.execute {
        sondeo?.cancel(false)
        sondeo = null
        cancelarReintento()
        avisos?.cerrar()
    }

    /**
     * Pregunta si pasó [Ajustes.intervaloMs] desde la última vez (aunque el
     * proceso se haya reiniciado entre medias). Para el servicio de una app
     * que corre de fondo: llamarlo tras cada tarea es barato.
     */
    fun quizas() = hilo.execute {
        if (plataforma.ahora() - plataforma.ultimoChequeo() < ajustes.intervaloMs) return@execute
        verificarAhora(forzar = true, silencioso = true)
    }

    /**
     * Pregunta (con el freno de [Ajustes.minEntreChequeosMs] salvo [forzar]) y,
     * si hay versión, la baja. [manual]: lo pidió la persona; baja aunque la
     * red tenga medidor. [listo] corre cuando el hub contestó (o falló).
     */
    fun verificar(forzar: Boolean, manual: Boolean = false, silencioso: Boolean = false, listo: (() -> Unit)? = null) =
        hilo.execute { verificarAhora(forzar, silencioso, manual, listo) }

    /** La app volvió al frente: reconecta el socket, sigue la descarga cortada y pregunta. */
    fun alVolverAlFrente() = hilo.execute {
        avisos?.reconectarAhora()
        reintentarYa()
        verificarAhora(forzar = false, silencioso = false)
        if (instalarAlFrente && estado.fase == Fase.LISTO) {
            // El aviso ya venció con la app detrás: una vez, el instalador.
            instalarAlFrente = false
            instalarAhora(conDialogo = true, alTerminar = null)
        }
    }

    /** La red cambió. [otra]: es otra red (el socket viejo quedó colgado). */
    fun alCambiarRed(otra: Boolean) = hilo.execute {
        if (otra) avisos?.rehacer() else avisos?.reconectarAhora()
        reintentarYa()
    }

    /**
     * Instala el APK bajado. Sin [conDialogo] solo si va sin preguntar. [listo]
     * recibe lo que contestó Android (ver [Plataforma.instalar]) o `sin_apk`,
     * `en_curso` o `hace_falta_dialogo`.
     */
    fun instalar(conDialogo: Boolean, listo: ((String) -> Unit)? = null) = hilo.execute {
        instalarAhora(conDialogo, listo)
    }

    /** Con [Ajustes.autoInstalar]: instala sin preguntar si [Ajustes.puedeInstalar] deja. Una vez por versión. */
    fun instalarSiListo() = hilo.execute { instalarSiListoAhora() }

    // -------------------------------------------------------------- lógica

    private fun configurado() = plataforma.hub().isNotBlank() && plataforma.app().isNotBlank()

    private fun verificarAhora(
        forzar: Boolean,
        silencioso: Boolean,
        manual: Boolean = false,
        alTerminar: (() -> Unit)? = null,
    ) {
        if (!configurado() || estado.fase == Fase.INSTALANDO) {
            alTerminar?.invoke()
            return
        }
        if (estado.fase == Fase.DESCARGANDO) {
            // Ya se sabe que hay versión y va en camino.
            alTerminar?.invoke()
            return
        }
        if (!forzar && plataforma.ahora() - plataforma.ultimoChequeo() < ajustes.minEntreChequeosMs) {
            // Se preguntó hace nada. Si había versión, que siga (reusa lo bajado).
            ultima?.let { descargar(it, manual) }
            alTerminar?.invoke()
            return
        }
        if (alTerminar != null) alTerminarConsulta += alTerminar
        if (consultando) return
        consultando = true
        val antes = estado
        // Con una descarga cortada a la espera o un APK listo, se sigue
        // diciendo eso mientras se pregunta: si no, parpadearía.
        if (!silencioso && pendiente == null && antes.fase != Fase.LISTO) {
            cambiar(antes.copy(fase = Fase.VERIFICANDO, error = null))
        }
        io.execute {
            val r = runCatching {
                var v: VersionDisponible? = null
                plataforma.despierto {
                    v = consulta.preguntar(plataforma.hub(), plataforma.app(), plataforma.cuerpoConsulta())
                }
                v
            }
            hilo.execute {
                consultando = false
                plataforma.guardarUltimoChequeo(plataforma.ahora())
                alResponder(r, antes, silencioso, manual)
                val esperando = alTerminarConsulta.toList()
                alTerminarConsulta.clear()
                esperando.forEach { it() }
            }
        }
    }

    private fun alResponder(r: Result<VersionDisponible?>, antes: Estado, silencioso: Boolean, manual: Boolean) {
        r.onSuccess { v ->
            if (v != null) {
                ultima = v
                descargar(v, manual)
                return
            }
            // El hub dice que no hay nada: o se instaló, o la versión se retiró.
            // Lo que estuviera bajado o a medias ya no se ofrece.
            ultima = null
            pendiente = null
            fallos = 0
            cancelarReintento()
            quitarAviso()
            if (listo != null) {
                listo?.second?.delete()
                listo = null
                plataforma.guardarListo(null, null)
            }
            descarga.limpiar()
            if (estado.fase != Fase.AL_DIA || estado.version != null) cambiar(Estado())
        }
        r.onFailure { e ->
            if (pendiente != null) {
                // Sin red para preguntar: la versión sigue pendiente y se reintenta.
                if (estado.fase == Fase.VERIFICANDO) cambiar(antes)
                programarReintento()
                return
            }
            if (estado.fase == Fase.LISTO) return
            if (!silencioso) {
                cambiar(Estado(Fase.ERROR, error = e.message ?: e.javaClass.simpleName))
            } else if (estado.fase == Fase.VERIFICANDO) {
                cambiar(antes)
            }
        }
    }

    private fun descargar(v: VersionDisponible, manual: Boolean) {
        if (estado.fase == Fase.INSTALANDO) return
        val l = listo
        if (l != null && l.first.build == v.build && l.second.isFile) {
            if (estado.fase != Fase.LISTO) cambiar(listoDe(l.first, l.second))
            return
        }
        pendiente = v
        pendienteManual = manual
        if (bajando != null) return // al terminar esa, sigue esta si es otra
        cancelarReintento()
        if (ajustes.soloWifi && !manual && plataforma.medido()) {
            if (estado.fase != Fase.ESPERANDO_WIFI || estado.build != v.build) {
                cambiar(Estado(Fase.ESPERANDO_WIFI, version = v.version, build = v.build, requerido = v.requerido))
            }
            return
        }
        bajando = v
        // Al reintentar se conserva lo que ya se llevaba: la barra no vuelve a
        // cero si la descarga sigue desde donde se cortó.
        var progreso = if (estado.build == v.build) estado.progreso else 0.0
        cambiar(Estado(Fase.DESCARGANDO, progreso, v.version, v.build, v.requerido))
        io.execute {
            // Un aviso por punto: el canal a Flutter no aguanta uno por cada 64 KB.
            var ultimoPct = -1
            val r = runCatching {
                var archivo: File? = null
                plataforma.despierto {
                    archivo = descarga.bajar(v) { p ->
                        progreso = p
                        val pct = (p * 100).toInt()
                        if (pct != ultimoPct) {
                            ultimoPct = pct
                            hilo.execute {
                                if (bajando === v) cambiar(Estado(Fase.DESCARGANDO, p, v.version, v.build, v.requerido))
                            }
                        }
                    }
                }
                archivo!!
            }
            hilo.execute { alBajar(v, r, progreso) }
        }
    }

    private fun alBajar(v: VersionDisponible, r: Result<File>, progreso: Double) {
        bajando = null
        r.onSuccess { apk ->
            listo = v to apk
            plataforma.guardarListo(v, apk)
            if (pendiente?.build == v.build) {
                pendiente = null
                fallos = 0
            }
            val minutos = if (ajustes.avisoMinutos >= 0) ajustes.avisoMinutos else v.avisoMinutos
            if (minutos > 0) {
                avisar(plataforma.ahora() + minutos * ajustes.minutoMs)
            } else {
                quitarAviso()
            }
            cambiar(listoDe(v, apk))
            instalarSiListoAhora()
        }
        r.onFailure { e ->
            // Con la versión y lo que se llevaba: quien muestra el estado puede
            // decir QUÉ se cortó y por dónde iba, y el reintento sigue desde ahí.
            cambiar(
                Estado(Fase.ERROR, progreso, v.version, v.build, v.requerido, error = e.message ?: e.javaClass.simpleName),
            )
        }
        val p = pendiente
        if (p != null && p.build != v.build) {
            descargar(p, pendienteManual) // salió otra mientras bajaba esta
        } else if (p != null) {
            programarReintento()
        }
    }

    /**
     * Vuelve a preguntar y a bajar dentro de un rato, cada vez más espaciado.
     * Preguntar primero es lo que se entera de que la versión se retiró o de
     * que salió otra.
     */
    private fun programarReintento() {
        if (pendiente == null || reintento != null) return
        val esperas = ajustes.esperasReintentoMs
        if (esperas.isEmpty()) return
        val espera = esperas[minOf(fallos, esperas.size - 1)]
        fallos++
        val manual = pendienteManual
        reintento = hilo.schedule({
            reintento = null
            verificarAhora(forzar = true, silencioso = true, manual = manual)
        }, espera, TimeUnit.MILLISECONDS)
    }

    /** Si una descarga cortada espera su turno (o espera Wi-Fi), que vaya ya. */
    private fun reintentarYa() {
        val p = pendiente ?: return
        if (bajando != null) return
        if (reintento == null && estado.fase != Fase.ESPERANDO_WIFI) return
        cancelarReintento()
        if (estado.fase == Fase.ESPERANDO_WIFI) {
            descargar(p, pendienteManual)
        } else {
            verificarAhora(forzar = true, silencioso = true, manual = pendienteManual)
        }
    }

    private fun cancelarReintento() {
        reintento?.cancel(false)
        reintento = null
    }

    private fun falta(): String? = if (plataforma.sinPreguntar()) null else "permiso"

    private fun listoDe(v: VersionDisponible, apk: File, porque: String? = falta()) =
        Estado(Fase.LISTO, 1.0, v.version, v.build, v.requerido, apk.path, falta = porque, instalaEn = instalaEn)

    // ------------------------------------------------------------- aviso

    /** Arranca (o sigue) la cuenta regresiva hasta [en]; al llegar, [alVencerAviso]. */
    private fun avisar(en: Long) {
        avisoTarea?.cancel(false)
        instalaEn = en
        instalarAlFrente = false
        plataforma.guardarInstalaEn(en)
        avisoTarea = hilo.schedule({
            avisoTarea = null
            alVencerAviso()
        }, maxOf(0L, en - plataforma.ahora()), TimeUnit.MILLISECONDS)
    }

    private fun quitarAviso() {
        avisoTarea?.cancel(false)
        avisoTarea = null
        instalarAlFrente = false
        if (instalaEn != 0L) {
            instalaEn = 0
            plataforma.guardarInstalaEn(0)
        }
    }

    /**
     * Llegó la hora avisada: se instala. Sin preguntar si Android lo deja; si
     * no, el instalador del sistema (la persona toca «Actualizar») si se puede
     * abrir una pantalla; con la app detrás en Android 10+, al volver al frente.
     */
    private fun alVencerAviso() {
        val l = listo ?: return
        if (estado.fase != Fase.LISTO || l.first.build != estado.build) return
        val conDialogo = plataforma.sinPreguntar() || plataforma.puedeAbrirPantalla()
        instalarAhora(conDialogo = conDialogo) { r ->
            if (r in LANZADA) return@instalarAhora
            instalarAlFrente = true
            // La notificación pasa de la cuenta regresiva a «toca para instalar».
            plataforma.alCambiar(estado)
        }
    }

    private fun instalarSiListoAhora() {
        if (!ajustes.autoInstalar) return
        if (instalaEn > 0) return // con aviso manda la cuenta regresiva
        val l = listo ?: return
        if (estado.fase != Fase.LISTO) return
        if (l.first.build == autoLanzada) return
        if (!ajustes.puedeInstalar()) return
        if (!plataforma.sinPreguntar()) return // la notificación de «lista» queda para la persona
        autoLanzada = l.first.build
        instalarAhora(conDialogo = false) { r ->
            if (r !in LANZADA) autoLanzada = -1
        }
    }

    private fun instalarAhora(conDialogo: Boolean, alTerminar: ((String) -> Unit)?) {
        val l = listo
        if (l == null || !l.second.isFile) {
            alTerminar?.invoke("sin_apk")
            return
        }
        if (instalando) {
            alTerminar?.invoke("en_curso")
            return
        }
        if (!conDialogo && !plataforma.sinPreguntar()) {
            alTerminar?.invoke("hace_falta_dialogo")
            return
        }
        instalando = true
        val (v, apk) = l
        cambiar(Estado(Fase.INSTALANDO, 1.0, v.version, v.build, v.requerido, apk.path))
        plataforma.instalar(apk, v.version, conDialogo) { r ->
            hilo.execute {
                instalando = false
                // Hace falta la persona, falló o Android no contestó: el APK
                // sigue listo y el botón vuelve.
                if (r != "instalada" && estado.fase == Fase.INSTALANDO) {
                    val porque = when (r) {
                        "confirmar", "permiso" -> r
                        else -> falta()
                    }
                    cambiar(listoDe(v, apk, porque))
                }
                alTerminar?.invoke(r)
            }
        }
    }

    private fun cambiar(e: Estado) {
        if (e == estado) return
        estado = e
        plataforma.alCambiar(e)
    }

    companion object {
        /** Resultados de [instalar] con los que la instalación sí arrancó. */
        val LANZADA = setOf("instalada", "dialogo", "sin_respuesta", "en_curso")

        /** Si la hora del aviso pasó con la app cerrada, este último aviso antes de instalar. */
        const val ULTIMO_AVISO_MS = 60_000L
    }
}
