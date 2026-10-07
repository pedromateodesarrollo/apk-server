import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

// El sitio lo sirve el propio hub desde la carpeta que apunte APK_MANAGER.
//
// `base` absoluta, al revés que print-server: la página de instalación vive en
// una ruta de verdad (`/i/<app>`, la que va en el código QR), y con rutas
// relativas el navegador pediría `/i/assets/…`. Por eso el hub va en la raíz
// de su dominio.
export default defineConfig({
  plugins: [vue()],
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
