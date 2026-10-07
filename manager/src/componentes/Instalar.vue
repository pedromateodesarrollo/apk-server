<script setup>
import { ref, computed, onMounted } from 'vue'
import QRCode from 'qrcode'
import { api, bytes, fecha, inicial } from '../api.js'

const props = defineProps({ app: String })

const datos = ref(null)
const error = ref('')
const qr = ref('')

// En un teléfono Android se ofrece bajar; en una computadora, el QR para
// abrir esta misma página desde el teléfono.
const esAndroid = /android/i.test(navigator.userAgent)

onMounted(async () => {
  try {
    datos.value = await api.get(`/v1/apps/${props.app}`)
    document.title = `Instalar ${datos.value.nombre}`
    qr.value = await QRCode.toString(location.href.split('#')[0], {
      type: 'svg',
      margin: 0,
      errorCorrectionLevel: 'M',
    })
  } catch (e) {
    error.value = e.message
  }
})

const ultima = computed(() => datos.value?.ultima)
</script>

<template>
  <div class="instalar">
    <p v-if="error" class="aviso">{{ error }}</p>
    <p v-else-if="!datos" class="apagado">Cargando…</p>

    <template v-else>
      <img v-if="datos.icono" class="icono-app grande" :src="datos.icono" alt="" style="margin: 0 auto" />
      <div v-else class="icono-app grande" style="margin: 0 auto">{{ inicial(datos.nombre) }}</div>
      <h1>{{ datos.nombre }}</h1>
      <p v-if="datos.descripcion" class="apagado">{{ datos.descripcion }}</p>

      <template v-if="ultima">
        <p class="version">
          Versión {{ ultima.version }} · {{ bytes(ultima.bytes) }} · {{ fecha(ultima.publicado) }}
        </p>
        <a class="boton" :href="datos.instalar">Descargar e instalar</a>

        <div v-if="!esAndroid">
          <div class="qr" v-html="qr"></div>
          <p class="apagado">Escanéalo con el teléfono para abrir esta página allí.</p>
        </div>

        <div class="tarjeta" style="margin-top: 28px; text-align: left">
          <h3>Para instalar</h3>
          <ol>
            <li>Toca «Descargar e instalar» y abre el archivo al terminar.</li>
            <li>Si Android pregunta, permite instalar apps de esta fuente (solo la primera vez).</li>
            <li>Desde ahí la app se actualiza sola cuando sale una versión nueva.</li>
          </ol>
        </div>

        <div v-if="ultima.notas" class="tarjeta notas">
          <h3>Qué trae esta versión</h3>
          <p>{{ ultima.notas }}</p>
        </div>

        <p class="mono" style="margin-top: 22px">
          {{ datos.paquete }} · build {{ ultima.build }}<br />sha256 {{ ultima.sha256 }}
        </p>
      </template>
      <p v-else class="apagado">Todavía no hay una versión publicada.</p>
    </template>
  </div>
</template>
