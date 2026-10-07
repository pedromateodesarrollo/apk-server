<script setup>
import { ref, computed, onMounted } from 'vue'
import { api, sesion } from '../api.js'
import Apps from './Apps.vue'
import AppDetalle from './AppDetalle.vue'
import Llaves from './Llaves.vue'
import Usuarios from './Usuarios.vue'
import Cuenta from './Cuenta.vue'

const props = defineProps({ ruta: String })

const yo = ref(null)
const cargando = ref(true)
const correo = ref('')
const clave = ref('')
const error = ref('')
const enviando = ref(false)

// `#/panel`, `#/panel/llaves`, `#/panel/usuarios`, `#/panel/cuenta` o
// `#/panel/app/<slug>`.
const partes = computed(() => (props.ruta || '').split('/').filter(Boolean).slice(1))
const seccion = computed(() => partes.value[0] || 'apps')
const app = computed(() => (seccion.value === 'app' ? partes.value[1] : ''))

const secciones = computed(() => [
  ['apps', 'Apps'],
  ...(yo.value?.rol === 'admin' ? [['llaves', 'Llaves de API'], ['usuarios', 'Usuarios']] : []),
  ['cuenta', 'Mi cuenta'],
])

onMounted(async () => {
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
      <Cuenta v-else-if="seccion === 'cuenta'" :yo="yo" />
      <Apps v-else :yo="yo" />
    </main>
  </div>
</template>
