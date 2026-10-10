import { defineConfig } from 'vite'
import legacy from '@vitejs/plugin-legacy'
import vue from '@vitejs/plugin-vue'

// El sitio lo sirve el propio hub desde la carpeta que apunte APK_MANAGER.
//
// `base` absoluta, al revés que print-server: la página de instalación vive en
// una ruta de verdad (`/i/<app>`, la que va en el código QR), y con rutas
// relativas el navegador pediría `/i/assets/…`. Por eso el hub va en la raíz
// de su dominio.
export default defineConfig({
  plugins: [
    vue(),
    // La página de instalación se abre en el navegador del equipo que se va a
    // instalar, y en un almacén hay terminales viejas: una Zebra con Android
    // 8.1 y el Chrome de fábrica (≤ 68) dejaba `/i/<app>` en blanco por un
    // `??` (Chrome 80+). Los navegadores viejos cargan una copia aparte, con
    // la sintaxis rebajada y lo que les falta; los nuevos no la tocan.
    legacy({ targets: ['chrome >= 49', 'android >= 5'] }),
  ],
  base: '/',
  build: { outDir: 'dist', emptyOutDir: true },
  server: {
    // En desarrollo el API está en el hub local.
    proxy: {
      '/v1': { target: 'http://localhost:3131', ws: true },
      '/salud': 'http://localhost:3131',
      '/archivos': 'http://localhost:3131',
      '/install': 'http://localhost:3131',
    },
  },
})
