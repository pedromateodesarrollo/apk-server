<script setup>
import { ref, reactive, onMounted } from 'vue'
import { api } from '../api.js'

const props = defineProps({ yo: Object })

// El correo de salida (con él salen las invitaciones al panel y los enlaces
// de «¿Olvidaste tu clave?»). La clave no vuelve del hub: el campo queda
// vacío y, si se deja así, se conserva la que estaba.
const correo = reactive({ host: '', puerto: 587, seguridad: 'starttls', remitente: '', usuario: '', clave: '', nombre: '' })
const estado = ref(null)
const error = ref('')
const listo = ref('')
const guardando = ref(false)
const probando = ref(false)
const puertos = { tls: 465, starttls: 587, ninguna: 25 }

function llena(c) {
  estado.value = c || { configurado: false, clave_puesta: false }
  Object.assign(correo, {
    host: c?.host || '',
    puerto: c?.puerto || 587,
    seguridad: c?.seguridad || 'starttls',
    remitente: c?.remitente || '',
    usuario: c?.usuario || '',
    clave: '',
    nombre: c?.nombre || '',
  })
}

function cambiaSeguridad() {
  // El puerto de siempre para cada una, si no lo habían cambiado a mano.
  if (Object.values(puertos).includes(Number(correo.puerto))) correo.puerto = puertos[correo.seguridad]
}

async function guarda() {
  error.value = ''
  listo.value = ''
  guardando.value = true
  try {
    llena(await api.put('/v1/org/correo', { ...correo, puerto: Number(correo.puerto) }))
    listo.value = 'Guardado. Prueba que llegue antes de invitar a alguien.'
  } catch (e) {
    error.value = e.message
  } finally {
    guardando.value = false
  }
}

async function prueba() {
  error.value = ''
  listo.value = ''
  probando.value = true
  try {
    const r = await api.post('/v1/org/correo/prueba')
    listo.value = `Se mandó un correo de prueba a ${r.para}. Si llega, las invitaciones también llegarán.`
  } catch (e) {
    error.value = e.message
  } finally {
    probando.value = false
  }
}

async function quita() {
  error.value = ''
  listo.value = ''
  try {
    llena(await api.put('/v1/org/correo', { quitar: true }))
    listo.value = 'Sin correo de salida: las invitaciones vuelven a ser un enlace para compartir.'
  } catch (e) {
    error.value = e.message
  }
}

onMounted(async () => {
  try {
    llena(await api.get('/v1/org/correo'))
  } catch (e) {
    error.value = e.message
  }
})
</script>

<template>
  <div class="cabecera-seccion"><h2>Organización</h2></div>
  <p class="apagado">{{ props.yo.organizacion }}</p>

  <p v-if="!estado && error" class="aviso">{{ error }}</p>
  <p v-else-if="!estado" class="apagado">Cargando…</p>

  <form v-else class="tarjeta" style="max-width: 680px" @submit.prevent="guarda">
    <h3>Correo de salida</h3>
    <p class="apagado" style="font-size: 14px">
      Con él salen las invitaciones al panel y, en la entrada, «¿Olvidaste tu
      clave?». apk-server no usa el correo de ningún otro sistema: pon una
      cuenta de tu organización (mejor una solo para esto). En Gmail, la clave
      es una
      <a href="https://myaccount.google.com/apppasswords" target="_blank" rel="noopener">contraseña de aplicación</a>,
      no la de entrar. Sin él, invitar es un enlace que compartes tú.
    </p>
    <div style="margin-top: 8px; font-size: 14px">
      {{ estado.configurado ? `Configurado: sale como ${estado.remitente}.` : 'Todavía no hay correo de salida.' }}
    </div>
    <div style="display: grid; gap: 0 14px; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr))">
      <div><label>Servidor SMTP</label><input v-model="correo.host" placeholder="smtp.gmail.com" autocomplete="off" required /></div>
      <div>
        <label>Seguridad</label>
        <select v-model="correo.seguridad" @change="cambiaSeguridad">
          <option value="starttls">STARTTLS (587)</option>
          <option value="tls">TLS directo (465)</option>
          <option value="ninguna">Sin cifrar (solo en una red propia)</option>
        </select>
      </div>
      <div><label>Puerto</label><input v-model="correo.puerto" type="number" min="1" max="65535" required /></div>
      <div><label>Remitente</label><input v-model="correo.remitente" type="email" placeholder="avisos@tu-empresa.com" required /></div>
      <div>
        <label>Nombre que se ve <span class="apagado" style="font-weight: 400">(opcional)</span></label>
        <input v-model="correo.nombre" placeholder="apk-server de tu empresa" />
      </div>
      <div><label>Usuario</label><input v-model="correo.usuario" placeholder="Normalmente, el mismo remitente" autocomplete="off" /></div>
      <div>
        <label>Clave</label>
        <input
          v-model="correo.clave"
          type="password"
          autocomplete="new-password"
          :placeholder="estado.clave_puesta ? 'Puesta: vacía para no cambiarla' : ''"
        />
      </div>
    </div>
    <!-- `div` y no `p`: `.tarjeta p` les pondría el color apagado. -->
    <div v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</div>
    <div v-if="listo" class="exito" style="margin: 12px 0 0">{{ listo }}</div>
    <div style="display: flex; gap: 8px; flex-wrap: wrap; align-items: center; margin-top: 14px">
      <button class="boton" :disabled="guardando">{{ guardando ? 'Guardando…' : 'Guardar' }}</button>
      <button type="button" class="boton suave chico" :disabled="!estado.configurado || probando" @click="prueba">
        {{ probando ? 'Mandando…' : 'Mandarme un correo de prueba' }}
      </button>
      <button v-if="estado.configurado" type="button" class="boton suave chico" @click="quita">Quitar</button>
    </div>
  </form>
</template>
