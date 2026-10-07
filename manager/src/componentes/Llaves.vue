<script setup>
import { ref, onMounted } from 'vue'
import { api, hace } from '../api.js'

const llaves = ref([])
const apps = ref([])
const error = ref('')
const creada = ref(null)
const nombre = ref('')
const permisos = ref(['publicar'])
const alcance = ref([])
const confirmando = ref(null)

const todos = [
  ['publicar', 'Publicar versiones (y cambiar sus notas, marcarlas o retirarlas)'],
  ['leer', 'Leer apps, versiones y equipos'],
  ['admin', 'Administrar todo (usuarios, llaves, apps)'],
]

async function carga() {
  try {
    llaves.value = (await api.get('/v1/llaves')).llaves
    apps.value = (await api.get('/v1/apps')).apps
    error.value = ''
  } catch (e) {
    error.value = e.message
  }
}

async function crea() {
  try {
    creada.value = await api.post('/v1/llaves', {
      nombre: nombre.value,
      permisos: permisos.value,
      apps: alcance.value,
    })
    nombre.value = ''
    alcance.value = []
    await carga()
  } catch (e) {
    error.value = e.message
  }
}

async function revoca(l) {
  if (confirmando.value !== l.id) {
    confirmando.value = l.id
    setTimeout(() => (confirmando.value === l.id ? (confirmando.value = null) : null), 4000)
    return
  }
  await api.del(`/v1/llaves/${l.id}`)
  confirmando.value = null
  await carga()
}

onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion"><h2>Llaves de API</h2></div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="creada" class="exito">
    <strong>{{ creada.nombre }}</strong> — cópiala ahora: no se vuelve a enseñar.
    <div class="secreto">{{ creada.llave }}</div>
    <button class="boton suave chico" style="margin-top: 10px" @click="creada = null">Ya la copié</button>
  </div>

  <div class="tarjeta" style="margin-bottom: 20px">
    <h3>Crear una llave</h3>
    <p class="apagado">
      Una por script de publicación: así se sabe cuál revocar sin dejar mudos a
      los demás. Guárdala fuera del repositorio (un archivo con permisos 600 o
      un secreto del CI).
    </p>
    <label>Nombre</label>
    <input v-model="nombre" placeholder="Publicación del proyecto inventario" style="max-width: 420px" />

    <label>Permisos</label>
    <div v-for="[id, texto] in todos" :key="id" style="margin-bottom: 4px">
      <label style="display: flex; gap: 8px; align-items: center; font-weight: 400; margin: 0">
        <input type="checkbox" :value="id" v-model="permisos" style="width: auto" />
        <span>{{ texto }} <code class="apagado">{{ id }}</code></span>
      </label>
    </div>

    <label>Apps <span class="apagado">(ninguna marcada = todas)</span></label>
    <div style="display: flex; flex-wrap: wrap; gap: 4px 16px">
      <label v-for="a in apps" :key="a.slug" style="display: flex; gap: 6px; align-items: center; font-weight: 400; margin: 0">
        <input type="checkbox" :value="a.slug" v-model="alcance" style="width: auto" />
        <code>{{ a.slug }}</code>
      </label>
    </div>
    <button class="boton" style="margin-top: 14px" :disabled="!nombre || !permisos.length" @click="crea">Crear</button>
  </div>

  <table v-if="llaves.length" class="tarjetas">
    <thead>
      <tr><th>Nombre</th><th>Prefijo</th><th>Permisos</th><th>Apps</th><th>Último uso</th><th></th></tr>
    </thead>
    <tbody>
      <tr v-for="l in llaves" :key="l.id" :style="l.revocada ? 'opacity:.45' : ''">
        <td data-t="Nombre">{{ l.nombre }}</td>
        <td data-t="Prefijo"><code>cak_{{ l.prefijo }}_…</code></td>
        <td data-t="Permisos" class="apagado" style="font-size: 13px">{{ (l.permisos || []).join(', ') }}</td>
        <td data-t="Apps" class="apagado" style="font-size: 13px">{{ (l.apps || []).length ? l.apps.join(', ') : 'todas' }}</td>
        <td data-t="Último uso" class="apagado" style="font-size: 13px">{{ hace(l.ultimo_uso) }}</td>
        <td>
          <span v-if="l.revocada" class="apagado">revocada</span>
          <button v-else class="boton chico" :class="confirmando === l.id ? 'peligro' : 'suave'" @click="revoca(l)">
            {{ confirmando === l.id ? '¿Seguro?' : 'Revocar' }}
          </button>
        </td>
      </tr>
    </tbody>
  </table>
</template>
