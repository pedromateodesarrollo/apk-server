<script setup>
import { ref, computed, onMounted } from 'vue'
import Landing from './componentes/Landing.vue'
import Docs from './componentes/Docs.vue'
import Panel from './componentes/Panel.vue'
import Activar from './componentes/Activar.vue'
import Instalar from './componentes/Instalar.vue'

// La página de instalación va por ruta de verdad (`/i/<app>`): es la que se
// imprime en un QR y se manda por mensaje, y tiene que verse limpia. El resto
// va por el hash, que no necesita nada del servidor.
const instalar = location.pathname.match(/^\/i\/([a-z0-9][a-z0-9-]{0,62})\/?$/)?.[1] || ''

const ruta = ref(location.hash.slice(1) || '/')
onMounted(() => {
  window.addEventListener('hashchange', () => {
    ruta.value = location.hash.slice(1) || '/'
    if (!location.hash.includes('#', 1)) window.scrollTo(0, 0)
  })
})

const vista = computed(() => {
  if (instalar) return Instalar
  if (ruta.value.startsWith('/docs')) return Docs
  if (ruta.value.startsWith('/panel')) return Panel
  if (ruta.value.startsWith('/activar/')) return Activar
  return Landing
})
const enDocs = computed(() => ruta.value.startsWith('/docs'))
const enPanel = computed(() => ruta.value.startsWith('/panel'))
</script>

<template>
  <header class="barra" v-if="!instalar">
    <div class="contenedor">
      <a href="/#/" class="logo">apk<span>-server</span></a>
      <nav>
        <a href="/#/" :class="{ activo: !enDocs && !enPanel }">Inicio</a>
        <a href="/#/docs" :class="{ activo: enDocs }">Documentación</a>
        <a href="/#/panel" class="boton chico">Panel</a>
      </nav>
    </div>
  </header>

  <component :is="vista" :ruta="ruta" :app="instalar" />

  <footer class="pie" v-if="!enPanel && !instalar">
    <div class="contenedor">
      <span>apk-server · software libre bajo Apache-2.0</span>
      <nav>
        <a href="https://github.com/pedromateodesarrollo/apk-server">Código</a>
        <a href="/#/docs">Documentación</a>
        <a href="/#/panel">Panel</a>
      </nav>
    </div>
  </footer>
</template>
