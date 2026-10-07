<script setup>
import { ref, onMounted } from 'vue'
import { api, bytes, hace, inicial } from '../api.js'

const props = defineProps({ yo: Object })

const apps = ref([])
const error = ref('')
const cargando = ref(true)
const creando = ref(false)
const slug = ref('')
const nombre = ref('')
const descripcion = ref('')

async function carga() {
  try {
    apps.value = (await api.get('/v1/apps')).apps
    error.value = ''
  } catch (e) {
    error.value = e.message
  } finally {
    cargando.value = false
  }
}

async function crea() {
  try {
    const a = await api.post('/v1/apps', {
      slug: slug.value.trim().toLowerCase(),
      nombre: nombre.value.trim(),
      descripcion: descripcion.value.trim(),
    })
    location.hash = `#/panel/app/${a.slug}`
  } catch (e) {
    error.value = e.message
  }
}

// El identificador se propone a partir del nombre mientras nadie lo toque.
let slugTocado = false
function alNombre() {
  if (slugTocado) return
  slug.value = nombre.value
    .toLowerCase()
    .normalize('NFD').replace(/[̀-ͯ]/g, '')
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 63)
}

onMounted(carga)
</script>

<template>
  <div class="cabecera-seccion">
    <h2>Apps</h2>
    <button v-if="props.yo.rol === 'admin' && !creando" class="boton chico" @click="creando = true">
      Nueva app
    </button>
  </div>
  <p v-if="error" class="aviso">{{ error }}</p>

  <div v-if="creando" class="tarjeta" style="margin-bottom: 20px; max-width: 520px">
    <h3>Nueva app</h3>
    <p class="apagado">
      Una app es un <code>applicationId</code> de Android. Si tienes dos sabores
      con distinto <code>applicationId</code> (el de una marca y el genérico),
      son dos apps: Android nunca actualiza uno con el otro.
    </p>
    <label>Nombre</label>
    <input v-model="nombre" placeholder="Inventario" @input="alNombre" />
    <label>Identificador</label>
    <input v-model="slug" placeholder="inventario" @input="slugTocado = true" />
    <p class="apagado" style="font-size: 13px; margin: 6px 0 0">
      Va en las direcciones públicas (<code>/install/{{ slug || 'inventario' }}</code>)
      y dentro de la app compilada: no se cambia después.
    </p>
    <label>Descripción <span class="apagado">(opcional)</span></label>
    <input v-model="descripcion" placeholder="Para qué es, en una línea" />
    <div style="display: flex; gap: 10px; margin-top: 16px">
      <button class="boton" :disabled="!slug || !nombre" @click="crea">Crear</button>
      <button class="boton suave" @click="creando = false">Cancelar</button>
    </div>
  </div>

  <p v-if="cargando" class="apagado">Cargando…</p>
  <div v-else-if="!apps.length && !creando" class="tarjeta">
    <h3>Todavía no hay apps</h3>
    <p>Crea la primera y publica su APK desde el panel o con un <code>curl</code> (ver la documentación).</p>
  </div>

  <div class="apps">
    <a v-for="a in apps" :key="a.id" class="app-tarjeta" :href="`#/panel/app/${a.slug}`">
      <img v-if="a.tiene_icono" class="icono-app" :src="`/v1/apps/${a.slug}/icono`" alt="" />
      <div v-else class="icono-app">{{ inicial(a.nombre) }}</div>
      <div style="min-width: 0">
        <h3>{{ a.nombre }}</h3>
        <div class="datos">
          <code>{{ a.slug }}</code>
          <template v-if="a.ultima_version">
            · {{ a.ultima_version }} <span class="apagado">({{ a.ultima_build }})</span>
            <span v-if="a.ultima_requerida" class="nueva rojo">requerida</span>
            <br />publicada {{ hace(a.ultima_publicada) }}
          </template>
          <template v-else> · sin versiones</template>
          <br />
          {{ a.instalaciones }} equipos en 30 días<template v-if="a.instalaciones">, {{ a.al_dia }} al día</template>
          <template v-if="a.conectadas"> · <span class="estado"><span class="punto ok"></span>{{ a.conectadas }} conectados</span></template>
          <br />{{ a.versiones }} versiones · {{ bytes(a.bytes) }}
        </div>
      </div>
    </a>
  </div>
</template>
