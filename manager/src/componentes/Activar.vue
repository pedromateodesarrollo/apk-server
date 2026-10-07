<script setup>
import { ref, onMounted } from 'vue'
import { api, sesion } from '../api.js'

const props = defineProps({ ruta: String })

const token = (props.ruta || '').split('/')[2] || ''
const info = ref(null)
const error = ref('')
const clave = ref('')
const otra = ref('')
const enviando = ref(false)

// Quien ya tiene sesión abierta y abre un enlace de clave casi siempre no lo
// necesita (es uno viejo, o uno de respaldo). Se le dice, y el formulario
// queda a un clic por si de verdad quiere cambiarla.
const yo = ref(null)
const aunAsi = ref(false)

onMounted(async () => {
  if (sesion.token) {
    try { yo.value = await api.get('/v1/yo') } catch { /* sesión vencida: da igual */ }
  }
  try {
    info.value = await api.get(`/v1/auth/invitacion/${encodeURIComponent(token)}`)
  } catch (e) {
    error.value = e.message
  }
})

async function activa() {
  error.value = ''
  if (clave.value !== otra.value) {
    error.value = 'Las dos claves no coinciden'
    return
  }
  enviando.value = true
  try {
    const d = await api.post('/v1/auth/activar', { token, clave: clave.value })
    sesion.token = d.token
    // Que el enlace no se quede en el historial con el token dentro.
    history.replaceState(null, '', '/#/panel')
    location.reload()
  } catch (e) {
    error.value = e.message
  } finally {
    enviando.value = false
  }
}
</script>

<template>
  <div class="contenedor" style="padding: 56px 22px; max-width: 460px">
    <h1 style="font-size: 28px">Pon tu clave</h1>
    <p v-if="!info && !error" class="apagado">Revisando el enlace…</p>
    <template v-else-if="info && info.vigente && yo?.correo === info.correo && !aunAsi">
      <p class="apagado">
        Ya tienes la sesión abierta como <strong>{{ info.correo }}</strong> y tu
        clave sigue valiendo. Este enlace solo sirve para poner una clave nueva.
      </p>
      <div style="display: flex; gap: 10px; flex-wrap: wrap; margin-top: 8px">
        <a class="boton" href="/#/panel">Ir al panel</a>
        <button class="boton suave" @click="aunAsi = true">Poner una clave nueva</button>
      </div>
    </template>
    <template v-else-if="info && info.vigente">
      <p class="apagado">Para entrar como <strong>{{ info.correo }}</strong>. Solo tú la sabes.</p>
      <p v-if="yo && yo.correo && yo.correo !== info.correo" class="apagado" style="font-size: 14px">
        Ahora tienes abierta la sesión de {{ yo.correo }}: al guardar, entras como {{ info.correo }}.
      </p>
      <form class="caja" @submit.prevent="activa">
        <label>Clave nueva</label>
        <input v-model="clave" type="password" autocomplete="new-password" minlength="10" required />
        <label>Otra vez</label>
        <input v-model="otra" type="password" autocomplete="new-password" minlength="10" required />
        <p class="apagado" style="font-size: 13px; margin-top: 6px">Diez caracteres o más.</p>
        <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
        <button class="boton" style="margin-top: 16px" :disabled="enviando">
          {{ enviando ? 'Un momento…' : 'Guardar y entrar' }}
        </button>
      </form>
    </template>
    <template v-else>
      <p class="aviso">{{ error || 'Este enlace ya venció.' }}</p>
      <p class="apagado">
        Si ya pusiste tu clave con él, entra con tu correo y esa clave. Si no,
        pídele otro enlace a quien te invitó.
      </p>
      <a class="boton" href="/#/panel" style="margin-top: 8px">Entrar al panel</a>
    </template>
  </div>
</template>
