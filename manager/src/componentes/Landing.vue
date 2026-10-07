<script setup>
const diagrama = `  Tu script de publicación         Hub                     Equipos
  ────────────────────────     ─────────────────      ─────────────────────
  POST /v1/apps/wms/versiones ─►  lee el APK,     ──►  WebSocket: «salió la 84»
  (curl --data-binary @app.apk)   lo guarda,           consulta, baja, instala
                                  avisa                (sin preguntar, Android 12+)
                                       ▲
                                       └── cada equipo dice qué build tiene
                                           y cuándo se vio por última vez`
</script>

<template>
  <section class="hero">
    <div class="contenedor">
      <span class="etiqueta">Código abierto · Apache-2.0</span>
      <h1>Tus apps Android, al día solas.</h1>
      <p class="lema">
        Publicas una versión con un <code>curl</code> y cada equipo la baja y la
        instala. Sin Play Store, sin pasar el APK por WhatsApp y sabiendo qué
        build tiene cada terminal.
      </p>
      <div class="acciones">
        <a href="#/docs" class="boton">Ver el API</a>
        <a href="https://github.com/pedromateodesarrollo/apk-server" class="boton suave">Código en GitHub</a>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <div class="diagrama">{{ diagrama }}</div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>Qué resuelve</h2>
      <div class="rejilla" style="margin-top: 22px">
        <div class="tarjeta">
          <h3>Apps de empresa sin tienda</h3>
          <p>Las terminales de un almacén, la app de un cliente, una herramienta interna: lo que no va a Play Store se reparte desde tu propio servidor.</p>
        </div>
        <div class="tarjeta">
          <h3>Se entera al momento</h3>
          <p>Cada app abre un WebSocket con el hub. Al publicar, todas se enteran en el acto; el sondeo cada hora queda de respaldo.</p>
        </div>
        <div class="tarjeta">
          <h3>No te deja publicar mal</h3>
          <p>El hub lee el APK: si el <code>applicationId</code>, el <code>versionCode</code> o la llave de firma no cuadran, lo rechaza antes de que llegue a un teléfono.</p>
        </div>
        <div class="tarjeta">
          <h3>Sabes qué tiene cada equipo</h3>
          <p>Qué build, qué modelo, qué Android, cuándo se vio por última vez y si está conectado ahora. Le pones nombre a cada terminal.</p>
        </div>
        <div class="tarjeta">
          <h3>Obligatoria cuando hace falta</h3>
          <p>Marca una versión como requerida y nadie se queda por debajo de ella, aunque después salgan otras opcionales.</p>
        </div>
        <div class="tarjeta">
          <h3>Un enlace para instalar</h3>
          <p>Cada app tiene su página con código QR. El equipo nuevo la escanea, instala y desde ahí se actualiza solo.</p>
        </div>
      </div>
    </div>
  </section>

  <section class="seccion">
    <div class="contenedor">
      <h2>En tres pasos</h2>
      <div class="pasos" style="margin-top: 22px">
        <div class="paso">
          <h3>Levanta el hub</h3>
          <p class="apagado">Un binario y un Postgres. <code>docker compose up -d</code> y listo.</p>
        </div>
        <div class="paso">
          <h3>Publica</h3>
          <pre>curl -X POST https://TU-HUB/v1/apps/mi-app/versiones \
  -H "authorization: Bearer cak_..." \
  --data-binary @app-release.apk</pre>
        </div>
        <div class="paso">
          <h3>Pon el cliente en la app</h3>
          <p class="apagado">El paquete Flutter pregunta, baja e instala (sin diálogo en Android 12+). Ver <a href="#/docs#clientes">clientes</a>.</p>
        </div>
      </div>
    </div>
  </section>
</template>
