<script setup>
import { ref } from 'vue'
import { api } from '../api.js'

const props = defineProps({ yo: Object })

const actual = ref('')
const nueva = ref('')
const otra = ref('')
const error = ref('')
const listo = ref(false)

async function cambia() {
  error.value = ''
  listo.value = false
  if (nueva.value !== otra.value) {
    error.value = 'Las dos claves nuevas no coinciden'
    return
  }
  try {
    await api.post(`/v1/usuarios/${props.yo.id}/clave`, { actual: actual.value, clave: nueva.value })
    actual.value = nueva.value = otra.value = ''
    listo.value = true
  } catch (e) {
    error.value = e.message
  }
}
</script>

<template>
  <div class="cabecera-seccion"><h2>Mi cuenta</h2></div>
  <p class="apagado">{{ props.yo.nombre }} · {{ props.yo.correo }} · {{ props.yo.organizacion }}</p>
  <form class="caja" @submit.prevent="cambia">
    <h3 style="margin-top: 18px">Cambiar la clave</h3>
    <label>Clave actual</label>
    <input v-model="actual" type="password" autocomplete="current-password" required />
    <label>Clave nueva</label>
    <input v-model="nueva" type="password" autocomplete="new-password" minlength="10" required />
    <label>Otra vez</label>
    <input v-model="otra" type="password" autocomplete="new-password" minlength="10" required />
    <p v-if="error" class="aviso" style="margin-top: 12px">{{ error }}</p>
    <p v-if="listo" class="apagado" style="margin-top: 12px">Listo: la clave cambió.</p>
    <button class="boton" style="margin-top: 16px">Cambiar</button>
  </form>
</template>
