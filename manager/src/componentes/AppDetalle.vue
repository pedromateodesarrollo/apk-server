<script setup>
import { ref, computed, onMounted, watch } from 'vue'
import QRCode from 'qrcode'
import { api, bytes, hace, fecha, inicial } from '../api.js'

const props = defineProps({ slug: String, yo: Object })

const app = ref(null)
const versiones = ref([])
const error = ref('')
const pestana = ref('versiones')
const esAdmin = computed(() => props.yo?.rol === 'admin')

async function carga() {
  try {
    const d = await api.get(`/v1/apps/${props.slug}/versiones`)
    app.value = d.app
    versiones.value = d.versiones
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

// ------------------------------------------------------------------ publicar

const archivo = ref(null)
const notas = ref('')
const requerido = ref(false)
const progreso = ref(0)
const subiendo = ref(false)
const publicada = ref(null)
const encima = ref(false)
const selector = ref(null)

function elige(f) {
  if (!f) return
  if (!f.name.toLowerCase().endsWith('.apk')) {
    error.value = `«${f.name}» no es un .apk`
    return
  }
  error.value = ''
  publicada.value = null
  archivo.value = f
}

function suelta(e) {
  encima.value = false
  elige(e.dataTransfer?.files?.[0])
}

async function publica() {
  subiendo.value = true
  progreso.value = 0
  error.value = ''
  try {
    const q = new URLSearchParams()
    if (requerido.value) q.set('requerido', '1')
    if (notas.value.trim()) q.set('notas', notas.value.trim())
    publicada.value = await api.sube(
      'POST',
      `/v1/apps/${props.slug}/versiones?${q}`,
      archivo.value,
      (p) => (progreso.value = p),
    )
    archivo.value = null
    notas.value = ''
    requerido.value = false
    await carga()
  } catch (e) {
    error.value = e.message
  } finally {
    subiendo.value = false
  }
}

// ------------------------------------------------------------------ versiones

const editando = ref(null)
const notasEdit = ref('')
const confirmando = ref(null)

async function cambia(v, cambios) {
  try {
    await api.patch(`/v1/apps/${props.slug}/versiones/${v.build}`, cambios)
    editando.value = null
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

function editaNotas(v) {
  editando.value = v.build
  notasEdit.value = v.notas
}

async function borra(v) {
  if (confirmando.value !== v.build) {
    confirmando.value = v.build
    setTimeout(() => (confirmando.value === v.build ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/apps/${props.slug}/versiones/${v.build}`)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

const ultimaBuild = computed(() => versiones.value.find((v) => !v.retirada)?.build)

// ------------------------------------------------------------------- equipos

const equipos = ref([])
const porBuild = ref([])
const dias = ref(30)
const nombrando = ref(null)
const nombreEdit = ref('')

async function cargaEquipos() {
  try {
    const d = await api.get(`/v1/apps/${props.slug}/instalaciones?dias=${dias.value}`)
    equipos.value = d.instalaciones
    porBuild.value = d.por_build
  } catch (e) {
    error.value = e.message
  }
}

const totalEquipos = computed(() => porBuild.value.reduce((s, b) => s + b.cuantas, 0))

async function guardaNombre(i) {
  try {
    await api.patch(`/v1/apps/${props.slug}/instalaciones/${i.id}`, { nombre: nombreEdit.value.trim() })
    i.nombre = nombreEdit.value.trim()
    nombrando.value = null
  } catch (e) {
    error.value = e.message
  }
}

async function olvida(i) {
  if (confirmando.value !== `i${i.id}`) {
    confirmando.value = `i${i.id}`
    setTimeout(() => (confirmando.value === `i${i.id}` ? (confirmando.value = null) : null), 4000)
    return
  }
  await api.del(`/v1/apps/${props.slug}/instalaciones/${i.id}`)
  await cargaEquipos()
}

const androides = {
  21: '5.0', 22: '5.1', 23: '6', 24: '7.0', 25: '7.1', 26: '8.0', 27: '8.1', 28: '9',
  29: '10', 30: '11', 31: '12', 32: '12L', 33: '13', 34: '14', 35: '15', 36: '16',
}
const android = (sdk) => (sdk ? `Android ${androides[sdk] || `SDK ${sdk}`}` : '')
const contexto = (c) =>
  Object.entries(c || {})
    .map(([k, v]) => `${k}: ${typeof v === 'object' ? JSON.stringify(v) : v}`)
    .join(' · ')

// ------------------------------------------------------------------ instalar

const pagina = computed(() => `${location.origin}/i/${props.slug}`)
const directo = computed(() => `${location.origin}/install/${props.slug}`)
const qr = ref('')
const copiado = ref('')

watch(pestana, async (p) => {
  if (p === 'equipos') await cargaEquipos()
  if (p === 'instalar' && !qr.value) {
    qr.value = await QRCode.toString(pagina.value, { type: 'svg', margin: 0, errorCorrectionLevel: 'M' })
  }
})

async function copia(texto, que) {
  try {
    await navigator.clipboard.writeText(texto)
    copiado.value = que
    setTimeout(() => (copiado.value = ''), 2000)
  } catch { /* sin portapapeles: el texto está a la vista */ }
}

const curl = computed(
  () => `curl -X POST "${location.origin}/v1/apps/${props.slug}/versiones?notas=Lo%20nuevo" \\
  -H "authorization: Bearer cak_..." \\
  --data-binary @build/app/outputs/flutter-apk/app-release.apk`,
)

// -------------------------------------------------------------------- ajustes

const nombreApp = ref('')
const descripcionApp = ref('')
const guardado = ref(false)

watch(app, (a) => {
  if (!a) return
  nombreApp.value = a.nombre
  descripcionApp.value = a.descripcion
})

async function guardaApp() {
  try {
    await api.patch(`/v1/apps/${props.slug}`, { nombre: nombreApp.value, descripcion: descripcionApp.value })
    guardado.value = true
    setTimeout(() => (guardado.value = false), 2000)
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

const iconoVersion = ref(0)
async function subeIcono(e) {
  const f = e.target.files?.[0]
  if (!f) return
  try {
    await api.sube('PUT', `/v1/apps/${props.slug}/icono`, f)
    iconoVersion.value++
    await carga()
  } catch (err) {
    error.value = err.message
  }
}

async function quitaIcono() {
  await api.del(`/v1/apps/${props.slug}/icono`)
  await carga()
}

async function borraApp() {
  if (confirmando.value !== 'app') {
    confirmando.value = 'app'
    setTimeout(() => (confirmando.value === 'app' ? (confirmando.value = null) : null), 4000)
    return
  }
  try {
    await api.del(`/v1/apps/${props.slug}`)
    location.hash = '#/panel'
  } catch (e) {
    error.value = e.message
  }
}

onMounted(carga)
</script>

<template>
  <p><a href="#/panel">← Apps</a></p>
  <p v-if="error" class="aviso">{{ error }}</p>

  <template v-if="app">
    <div class="cabecera-seccion" style="align-items: center">
      <img v-if="app.tiene_icono" class="icono-app" :src="`/v1/apps/${slug}/icono?v=${iconoVersion}`" alt="" />
      <div v-else class="icono-app">{{ inicial(app.nombre) }}</div>
      <div>
        <h2>{{ app.nombre }}</h2>
        <div class="apagado" style="font-size: 14px">
          <code>{{ app.slug }}</code>
          <template v-if="app.paquete"> · {{ app.paquete }}</template>
        </div>
      </div>
    </div>

    <div class="pestanas">
      <button :class="{ activo: pestana === 'versiones' }" @click="pestana = 'versiones'">Versiones</button>
      <button :class="{ activo: pestana === 'equipos' }" @click="pestana = 'equipos'">Equipos</button>
      <button :class="{ activo: pestana === 'instalar' }" @click="pestana = 'instalar'">Instalar</button>
      <button v-if="esAdmin" :class="{ activo: pestana === 'ajustes' }" @click="pestana = 'ajustes'">Ajustes</button>
    </div>

    <!-- ---------------------------------------------------------- versiones -->
    <template v-if="pestana === 'versiones'">
      <div
        class="soltar"
        :class="{ encima }"
        @dragover.prevent="encima = true"
        @dragleave="encima = false"
        @drop.prevent="suelta"
        @click="!archivo && selector.click()"
      >
        <input ref="selector" type="file" accept=".apk" style="display: none" @change="elige($event.target.files[0])" />
        <template v-if="!archivo">
          <strong>Publicar una versión:</strong> suelta aquí el APK o haz clic para elegirlo.
          <div style="font-size: 13px; margin-top: 4px">
            El hub lee del APK el paquete, la versión y la firma, y lo rechaza si no cuadran con esta app.
          </div>
        </template>
        <div v-else style="text-align: left; cursor: default" @click.stop>
          <div><strong>{{ archivo.name }}</strong> · {{ bytes(archivo.size) }}</div>
          <label>Notas de la versión <span class="apagado">(las ve quien actualiza)</span></label>
          <textarea v-model="notas" placeholder="Qué cambió"></textarea>
          <label style="display: flex; gap: 8px; align-items: center; font-weight: 400">
            <input type="checkbox" v-model="requerido" style="width: auto" />
            Obligatoria: quien esté por debajo tiene que instalarla
          </label>
          <div v-if="subiendo" class="barra-progreso"><div :style="{ width: `${progreso * 100}%` }"></div></div>
          <div style="display: flex; gap: 10px; margin-top: 14px">
            <button class="boton" :disabled="subiendo" @click="publica">
              {{ subiendo ? `Subiendo… ${Math.round(progreso * 100)} %` : 'Publicar' }}
            </button>
            <button class="boton suave" :disabled="subiendo" @click="archivo = null">Cancelar</button>
          </div>
        </div>
      </div>

      <div v-if="publicada" class="exito">
        <template v-if="publicada.ya_estaba">Esa versión ya estaba publicada ({{ publicada.version }}, build {{ publicada.build }}).</template>
        <template v-else>
          Publicada <strong>{{ publicada.version }}</strong> (build {{ publicada.build }}).
          Avisadas al instante: {{ publicada.avisadas }} instalaciones conectadas; las demás se enteran en su próxima consulta.
        </template>
      </div>

      <p v-if="!versiones.length" class="apagado">Sin versiones todavía.</p>
      <table v-else class="tarjetas">
        <thead>
          <tr><th>Versión</th><th>Publicada</th><th>Tamaño</th><th>Equipos</th><th>Descargas</th><th>Notas</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="v in versiones" :key="v.build" :style="v.retirada ? 'opacity:.5' : ''">
            <td data-t="Versión">
              <strong>{{ v.version }}</strong> <span class="apagado">({{ v.build }})</span>
              <span v-if="v.build === ultimaBuild" class="nueva verde">la que se ofrece</span>
              <span v-if="v.requerido" class="nueva rojo">obligatoria</span>
              <span v-if="v.retirada" class="nueva gris">retirada</span>
            </td>
            <td data-t="Publicada" class="apagado" :title="`${fecha(v.publicado)} · ${v.publicado_por}`">{{ hace(v.publicado) }}</td>
            <td data-t="Tamaño" class="apagado">{{ bytes(v.bytes) }}</td>
            <td data-t="Equipos" class="apagado">{{ v.instalaciones }}</td>
            <td data-t="Descargas" class="apagado">{{ v.descargas }}</td>
            <td data-t="Notas" style="max-width: 320px">
              <template v-if="editando === v.build">
                <textarea v-model="notasEdit"></textarea>
                <button class="boton chico" style="margin-top: 6px" @click="cambia(v, { notas: notasEdit })">Guardar</button>
                <button class="boton chico suave" style="margin: 6px 0 0 6px" @click="editando = null">Cancelar</button>
              </template>
              <span v-else class="apagado" style="white-space: pre-wrap; font-size: 14px">{{ v.notas || '—' }}</span>
            </td>
            <td style="white-space: nowrap">
              <button class="boton chico suave" @click="editaNotas(v)">Notas</button>
              <button class="boton chico suave" style="margin-left: 4px" @click="cambia(v, { requerido: !v.requerido })">
                {{ v.requerido ? 'Opcional' : 'Obligatoria' }}
              </button>
              <button class="boton chico suave" style="margin-left: 4px" @click="cambia(v, { retirada: !v.retirada })">
                {{ v.retirada ? 'Devolver' : 'Retirar' }}
              </button>
              <button
                v-if="v.retirada && esAdmin"
                class="boton chico"
                :class="confirmando === v.build ? 'peligro' : 'suave'"
                style="margin-left: 4px"
                @click="borra(v)"
              >
                {{ confirmando === v.build ? '¿Borrar del todo?' : 'Borrar' }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
      <p class="apagado" style="font-size: 13px">
        Retirar deja de ofrecerla y de servirla (la que salió mala); se puede devolver.
        Borrar quita el APK del disco y no tiene vuelta.
      </p>
    </template>

    <!-- ------------------------------------------------------------ equipos -->
    <template v-if="pestana === 'equipos'">
      <div style="display: flex; gap: 10px; align-items: center; margin-bottom: 14px; flex-wrap: wrap">
        <span class="apagado">Vistos en los últimos</span>
        <select v-model="dias" style="width: auto" @change="cargaEquipos">
          <option :value="1">1 día</option>
          <option :value="7">7 días</option>
          <option :value="30">30 días</option>
          <option :value="90">90 días</option>
          <option :value="365">un año</option>
        </select>
        <button class="boton chico suave" @click="cargaEquipos">Actualizar</button>
      </div>

      <div v-if="porBuild.length" class="reparto">
        <div v-for="b in porBuild" :key="b.build" class="fila">
          <span>{{ b.version || '—' }} <span class="apagado">({{ b.build ?? '?' }})</span></span>
          <div class="barrita">
            <div :class="{ vieja: b.build !== ultimaBuild }" :style="{ width: `${(b.cuantas / totalEquipos) * 100}%` }"></div>
          </div>
          <span class="apagado">{{ b.cuantas }}</span>
        </div>
      </div>

      <p v-if="!equipos.length" class="apagado">
        Ningún equipo ha preguntado en ese plazo. Aparecen cuando la app consulta
        con el cliente de apk-server (ver la documentación).
      </p>
      <table v-else class="tarjetas">
        <thead>
          <tr><th>Equipo</th><th>Modelo</th><th>Versión</th><th>Contexto</th><th>Visto</th><th></th></tr>
        </thead>
        <tbody>
          <tr v-for="i in equipos" :key="i.id">
            <td data-t="Equipo">
              <template v-if="nombrando === i.id">
                <input v-model="nombreEdit" placeholder="Terminal 3 — recepción" @keyup.enter="guardaNombre(i)" />
                <button class="boton chico" style="margin-top: 6px" @click="guardaNombre(i)">Guardar</button>
              </template>
              <template v-else>
                <strong>{{ i.nombre || 'Sin nombre' }}</strong>
                <a href="#" style="font-size: 13px; margin-left: 6px" @click.prevent="nombrando = i.id; nombreEdit = i.nombre">nombrar</a>
                <div class="mono">{{ i.huella || i.clave }}</div>
              </template>
            </td>
            <td data-t="Modelo" class="apagado">{{ [i.fabricante, i.modelo].filter(Boolean).join(' ') || '—' }}<br />{{ android(i.android) }}</td>
            <td data-t="Versión">
              {{ i.version || '—' }} <span class="apagado">({{ i.build }})</span>
              <span v-if="i.build !== ultimaBuild" class="nueva gris">vieja</span>
            </td>
            <td data-t="Contexto" class="apagado" style="font-size: 13px; max-width: 260px">{{ contexto(i.contexto) || '—' }}</td>
            <td data-t="Visto" :title="`desde ${fecha(i.primera_vez)} · IP ${i.ip}`">
              <span class="estado">
                <span class="punto" :class="{ ok: i.conectado }"></span>
                {{ i.conectado ? 'conectado' : hace(i.ultima_vez) }}
              </span>
            </td>
            <td>
              <button v-if="esAdmin" class="boton chico" :class="confirmando === `i${i.id}` ? 'peligro' : 'suave'" @click="olvida(i)">
                {{ confirmando === `i${i.id}` ? '¿Olvidarlo?' : 'Olvidar' }}
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </template>

    <!-- ----------------------------------------------------------- instalar -->
    <template v-if="pestana === 'instalar'">
      <div class="rejilla">
        <div class="tarjeta">
          <h3>Página de instalación</h3>
          <p>Para un equipo nuevo: se escanea el código, se baja el APK y desde ahí la app se actualiza sola.</p>
          <div class="qr" style="width: 200px; background: #fff; padding: 10px; border-radius: 12px; margin: 14px 0" v-html="qr"></div>
          <div class="secreto">{{ pagina }}</div>
          <div style="display: flex; gap: 8px; margin-top: 10px; flex-wrap: wrap">
            <button class="boton chico" @click="copia(pagina, 'pagina')">{{ copiado === 'pagina' ? 'Copiado' : 'Copiar enlace' }}</button>
            <a class="boton chico suave" :href="pagina" target="_blank">Abrir</a>
          </div>
        </div>
        <div class="tarjeta">
          <h3>Descarga directa</h3>
          <p>Siempre la última versión. Para un script o un MDM.</p>
          <div class="secreto">{{ directo }}</div>
          <button class="boton chico" style="margin-top: 10px" @click="copia(directo, 'directo')">{{ copiado === 'directo' ? 'Copiado' : 'Copiar' }}</button>
          <h3 style="margin-top: 22px">Publicar desde un script</h3>
          <pre style="font-size: 12px">{{ curl }}</pre>
        </div>
      </div>
    </template>

    <!-- ------------------------------------------------------------ ajustes -->
    <template v-if="pestana === 'ajustes' && esAdmin">
      <div class="tarjeta" style="max-width: 560px; margin-bottom: 18px">
        <label style="margin-top: 0">Nombre</label>
        <input v-model="nombreApp" />
        <label>Descripción</label>
        <input v-model="descripcionApp" />
        <button class="boton" style="margin-top: 14px" @click="guardaApp">{{ guardado ? 'Guardado' : 'Guardar' }}</button>
      </div>

      <div class="tarjeta" style="max-width: 560px; margin-bottom: 18px">
        <h3>Icono</h3>
        <p>PNG, JPEG o WebP de hasta 512 KB. Sale en el panel y en la página de instalación.</p>
        <input type="file" accept="image/png,image/jpeg,image/webp" style="margin-top: 10px" @change="subeIcono" />
        <button v-if="app.tiene_icono" class="boton chico suave" style="margin-top: 10px" @click="quitaIcono">Quitar icono</button>
      </div>

      <div class="tarjeta" style="max-width: 560px; margin-bottom: 18px">
        <h3>Lo que fijó el primer APK</h3>
        <p>De aquí en adelante, un APK con otro paquete o firmado con otra llave se rechaza.</p>
        <label>Paquete</label>
        <div class="mono">{{ app.paquete || 'todavía no hay versiones' }}</div>
        <label>Firma (sha256 del certificado)</label>
        <div class="mono">{{ app.firma || '—' }}</div>
      </div>

      <div class="tarjeta" style="max-width: 560px">
        <h3>Borrar la app</h3>
        <p>Solo se puede con la app sin versiones.</p>
        <button class="boton chico" style="margin-top: 10px" :class="confirmando === 'app' ? 'peligro' : 'suave'" @click="borraApp">
          {{ confirmando === 'app' ? '¿Seguro?' : 'Borrar la app' }}
        </button>
      </div>
    </template>
  </template>
</template>
