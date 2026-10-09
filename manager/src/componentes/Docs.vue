<script setup>
import { ref } from 'vue'
import { intro, autenticacion, clientes, puntos, errores, grupos } from '../docs.js'

// Abiertos por defecto los dos que más se buscan: publicar y consultar.
const abiertos = ref(new Set(['POST /v1/apps/:app/versiones', 'POST /v1/apps/:app/consulta']))
function alterna(p) {
  const k = `${p.metodo} ${p.ruta}`
  abiertos.value.has(k) ? abiertos.value.delete(k) : abiertos.value.add(k)
  abiertos.value = new Set(abiertos.value)
}
const abierto = (p) => abiertos.value.has(`${p.metodo} ${p.ruta}`)
const ancla = (g) => g.toLowerCase().replace(/[^a-z]/g, '')

// Convierte los backticks del texto en <code>. Escapa antes de insertar: el
// texto es nuestro, pero un renderizador que confía es una costumbre que se
// acaba pagando en el primer campo que venga de fuera.
function marca(texto = '') {
  const escapado = String(texto).replace(
    /[&<>"]/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' })[c],
  )
  return escapado.replace(/`([^`]+)`/g, '<code>$1</code>')
}
</script>

<template>
  <div class="contenedor docs">
    <aside class="docs-menu">
      <div class="grupo">Guía</div>
      <a href="#/docs">Empezar</a>
      <a href="#/docs#auth">Autenticación</a>
      <a href="#/docs#clientes">Clientes</a>
      <a href="#/docs#errores">Errores</a>
      <div class="grupo">Referencia</div>
      <a v-for="g in grupos" :key="g" :href="`#/docs#${ancla(g)}`">{{ g }}</a>
    </aside>

    <main>
      <h1>{{ intro.titulo }}</h1>
      <p class="apagado">{{ intro.texto }}</p>

      <h2 id="auth" style="margin-top: 34px">Autenticación</h2>
      <div v-for="a in autenticacion" :key="a.titulo" class="tarjeta" style="margin-bottom: 12px">
        <h3>{{ a.titulo }}</h3>
        <p v-html="marca(a.texto)"></p>
        <pre v-if="a.ejemplo" style="margin-top: 12px">{{ a.ejemplo }}</pre>
      </div>

      <h2 id="clientes" style="margin-top: 34px">Clientes</h2>
      <div v-for="c in clientes" :key="c.titulo" class="tarjeta" style="margin-bottom: 12px">
        <h3>{{ c.titulo }}</h3>
        <p v-html="marca(c.texto)"></p>
        <pre v-if="c.ejemplo" style="margin-top: 12px">{{ c.ejemplo }}</pre>
      </div>

      <template v-for="g in grupos" :key="g">
        <h2 :id="ancla(g)" style="margin-top: 40px">{{ g }}</h2>
        <div
          v-for="p in puntos.filter((x) => x.grupo === g)"
          :key="p.metodo + p.ruta"
          class="punto-final"
        >
          <header @click="alterna(p)">
            <span class="metodo" :class="p.metodo">{{ p.metodo }}</span>
            <span class="ruta">{{ p.ruta }}</span>
            <span class="acceso">{{ p.acceso }}</span>
          </header>
          <div class="cuerpo-doc" v-show="abierto(p)">
            <p>{{ p.resumen }}</p>

            <template v-if="p.cuerpo">
              <h3>Cuerpo</h3>
              <table>
                <thead>
                  <tr><th>Campo</th><th>Tipo</th><th>Obligatorio</th><th></th></tr>
                </thead>
                <tbody>
                  <tr v-for="c in p.cuerpo" :key="c[0]">
                    <td><code>{{ c[0] }}</code></td>
                    <td class="apagado">{{ c[1] }}</td>
                    <td class="apagado">{{ c[2] }}</td>
                    <td class="apagado" v-html="marca(c[3])"></td>
                  </tr>
                </tbody>
              </table>
            </template>

            <template v-if="p.consulta">
              <h3>Parámetros de consulta</h3>
              <table>
                <tbody>
                  <tr v-for="c in p.consulta" :key="c[0]">
                    <td><code>{{ c[0] }}</code></td>
                    <td class="apagado">{{ c[1] }}</td>
                    <td class="apagado" v-html="marca(c[3])"></td>
                  </tr>
                </tbody>
              </table>
            </template>

            <p v-if="p.nota" class="apagado" v-html="marca(p.nota)"></p>
            <template v-if="p.respuesta">
              <h3>Respuesta</h3>
              <pre>{{ p.respuesta }}</pre>
            </template>
            <template v-if="p.ejemplo">
              <h3>Ejemplo</h3>
              <pre>{{ p.ejemplo }}</pre>
            </template>
          </div>
        </div>
      </template>

      <h2 id="errores" style="margin-top: 40px">Errores</h2>
      <p class="apagado">
        El cuerpo de un error es siempre <code>{ "error", "mensaje" }</code>:
        <code>error</code> es un código estable para ramificar,
        <code>mensaje</code> es para enseñárselo a alguien.
      </p>
      <table>
        <thead><tr><th>HTTP</th><th>Código</th><th>Cuándo</th></tr></thead>
        <tbody>
          <tr v-for="e in errores" :key="e[1] + e[0]">
            <td><code>{{ e[0] }}</code></td>
            <td v-html="marca(e[1])"></td>
            <td class="apagado">{{ e[2] }}</td>
          </tr>
        </tbody>
      </table>
    </main>
  </div>
</template>
