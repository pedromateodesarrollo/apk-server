<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, sesion } from '../api.js'
import Apps from './Apps.vue'
import AppDetalle from './AppDetalle.vue'
import Llaves from './Llaves.vue'
import Usuarios from './Usuarios.vue'
import Organizacion from './Organizacion.vue'
import Cuenta from './Cuenta.vue'

const props = defineProps({ ruta: String })

const yo = ref(null)
const cargando = ref(true)
const correo = ref('')
const clave = ref('')
const error = ref('')
const enviando = ref(false)

// «¿Olvidaste tu clave?» solo se ofrece si el hub puede mandar el enlace:
// `/salud` dice si alguna organización tiene correo de salida. `modo` es la
// pantalla de la entrada: `entrar`, `recuperar` (pide el correo) o `pedido`
// (ya se mandó).
const puedeRecuperar = ref(false)
const modo = ref('entrar')

// `#/panel`, `#/panel/llaves`, `#/panel/usuarios`, `#/panel/organizacion`,
// `#/panel/cuenta` o `#/panel/app/<slug>`.
const partes = computed(() => (props.ruta || '').split('/').filter(Boolean).slice(1))
const seccion = computed(() => partes.value[0] || 'apps')
const app = computed(() => (seccion.value === 'app' ? partes.value[1] : ''))

const secciones = computed(() => [
  ['apps', 'Apps'],
  ...(yo.value?.rol === 'admin'
    ? [['llaves', 'Llaves de API'], ['usuarios', 'Usuarios'], ['organizacion', 'Organización']]
    : []),
  ['cuenta', 'Mi cuenta'],
])

onMounted(async () => {
  // No se espera: la entrada se enseña ya y el enlace aparece al saberlo.
  api.get('/salud').then((s) => (puedeRecuperar.value = !!s.recuperar)).catch(() => {})
  if (sesion.token) {
    try {
      yo.value = await api.get('/v1/yo')
    } catch {
      sesion.token = ''
    }
  }
  cargando.value = false
})

async function entra() {
  error.value = ''
  enviando.value = true
  try {
    const d = await api.post('/v1/auth/login', { correo: correo.value, clave: clave.value })
    sesion.token = d.token
    yo.value = await api.get('/v1/yo')
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

function aRecuperar() {
  error.value = ''
  modo.value = 'recuperar'
}

function aEntrar() {
  error.value = ''
  modo.value = 'entrar'
}

// El hub contesta lo mismo exista o no la cuenta, así que aquí tampoco se
// sabe: el mensaje dice «si ese correo tiene cuenta».
async function recupera() {
  error.value = ''
  enviando.value = true
  try {
    await api.post('/v1/auth/recuperar', { correo: correo.value })
    modo.value = 'pedido'
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}

function ve(id) {
  location.hash = id === 'apps' ? '#/panel' : `#/panel/${id}`
}

function sale() {
  sesion.token = ''
  yo.value = null
  location.hash = '#/panel'
}
</script>

<template>
  <div v-if="cargando" class="contenedor" style="padding: 60px 22px">
    <p class="apagado">Cargando…</p>
  </div>

  <div v-else-if="!yo" class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <template v-if="modo === 'recuperar'">
      <h1 style="font-size: 28px">Clave nueva</h1>
      <p class="apagado">
        Pon el correo con el que entras. Si tiene cuenta, te llega un enlace
        para poner una clave nueva.
      </p>
      <form class="caja" @submit.prevent="recupera">
        <label>Correo</label>
        <input v-model="correo" type="email" autocomplete="username" required />
        <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
        <button class="boton" style="margin-top: 18px" :disabled="enviando">
          {{ enviando ? 'Un momento…' : 'Mandarme el enlace' }}
        </button>
      </form>
      <p style="margin-top: 18px; font-size: 15px">
        <a href="#/panel" @click.prevent="aEntrar">Volver a la entrada</a>
      </p>
    </template>

    <template v-else-if="modo === 'pedido'">
      <h1 style="font-size: 28px">Revisa tu correo</h1>
      <p class="exito">
        Si ese correo tiene cuenta, te llegó un enlace para poner una clave
        nueva. Vence en 1 hora. Si no llega, mira en el correo no deseado o
        pídele uno a quien administra.
      </p>
      <a class="boton suave" href="#/panel" @click.prevent="aEntrar">Volver a la entrada</a>
    </template>

    <template v-else>
      <h1 style="font-size: 28px">Entrar</h1>
      <p class="apagado">
        Con la cuenta de tu organización. Si todavía no tienes, pídele una
        invitación a quien administra este hub.
      </p>
      <form class="caja" @submit.prevent="entra">
        <label>Correo</label>
        <input v-model="correo" type="email" autocomplete="username" required />
        <label>Clave</label>
        <input v-model="clave" type="password" autocomplete="current-password" required />
        <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
        <button class="boton" style="margin-top: 18px" :disabled="enviando">
          {{ enviando ? 'Un momento…' : 'Entrar' }}
        </button>
      </form>
      <p v-if="puedeRecuperar" style="margin-top: 18px; font-size: 15px">
        <a href="#/panel" @click.prevent="aRecuperar">¿Olvidaste tu clave?</a>
      </p>
    </template>
  </div>

  <div v-else class="app">
    <aside class="lateral">
      <button
        v-for="[id, titulo] in secciones"
        :key="id"
        :class="{ activo: seccion === id || (id === 'apps' && seccion === 'app') }"
        @click="ve(id)"
      >
        {{ titulo }}
      </button>
      <hr style="border: 0; border-top: 1px solid var(--borde); margin: 14px 0" />
      <button @click="sale">Salir</button>
    </aside>

    <main class="contenido">
      <p class="apagado" style="font-size: 14px; margin-bottom: 14px">
        {{ yo.organizacion }} · {{ yo.correo }} ({{ yo.rol }})
      </p>
      <AppDetalle v-if="app" :key="app" :slug="app" :yo="yo" />
      <Llaves v-else-if="seccion === 'llaves'" />
      <Usuarios v-else-if="seccion === 'usuarios'" :yo="yo" />
      <Organizacion v-else-if="seccion === 'organizacion'" :yo="yo" />
      <Cuenta v-else-if="seccion === 'cuenta'" :yo="yo" />
      <Apps v-else :yo="yo" />
    </main>
  </div>
</template>
