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

onMounted(async () => {
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
    <template v-else-if="info && info.vigente">
      <p class="apagado">Para entrar como <strong>{{ info.correo }}</strong>. Solo tú la sabes.</p>
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
      <p class="apagado">Pídele otro a quien te invitó.</p>
    </template>
  </div>
</template>
