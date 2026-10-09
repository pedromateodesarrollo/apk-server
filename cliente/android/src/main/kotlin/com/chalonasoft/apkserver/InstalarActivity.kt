package com.chalonasoft.apkserver

import android.app.Activity
import android.os.Bundle
import android.widget.Toast

/**
 * Lo que abre la notificación de «lista». Transparente: instala y se va.
 *
 * Es una pantalla, y no un receptor, porque desde Android 12 una notificación
 * no puede abrir una pantalla pasando por un receptor, y la del sistema (la de
 * confirmar, o la de «Permitir de esta fuente») solo sale con la app al
 * frente. Mientras esta está abierta, lo está.
 */
class InstalarActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val a = ApkServer.de(this)
        a.instalar(conDialogo = true) { r ->
            if (isFinishing || isDestroyed) return@instalar
            when (r) {
                "sin_apk" -> {
                    // El sistema limpió la caché o ya se instaló: se pregunta de nuevo.
                    Toast.makeText(this, "Buscando la actualización de nuevo…", Toast.LENGTH_SHORT).show()
                    a.verificar(forzar = true, manual = true)
                }
                "error" -> Toast.makeText(this, "No se pudo instalar la actualización", Toast.LENGTH_LONG).show()
            }
            finish()
        }
    }
}
