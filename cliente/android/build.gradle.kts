// apk-server para Android: que una app se actualice sola desde su hub.
// Consulta, aviso por WebSocket, descarga en segundo plano, instalación sin
// preguntar (Android 12+) y la notificación de «lista». Ver README.md.
//
// Sin versiones de plugins aquí: sola, las pone settings.gradle.kts; dentro de
// una app, las de la app (así no se mezclan dos AGP en un mismo build).
plugins {
    id("com.android.library")
}

// AGP 9 trae Kotlin incluido salvo que la app lo apague
// (`android.builtInKotlin=false`, que es lo que escribe el migrador de Flutter
// 3.47). Con AGP 8, o con el de AGP 9 apagado, el plugin de Kotlin va aquí.
val agpMayor = com.android.Version.ANDROID_GRADLE_PLUGIN_VERSION.substringBefore('.').toInt()
val kotlinIncluido =
    agpMayor >= 9 &&
        (providers.gradleProperty("android.builtInKotlin").orNull?.toBoolean() ?: true)
if (!kotlinIncluido) {
    apply(plugin = "org.jetbrains.kotlin.android")
}

extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

group = "com.chalonasoft.apkserver"
version = "0.2.0"

android {
    namespace = "com.chalonasoft.apkserver"
    compileSdk = 36

    defaultConfig {
        minSdk = 21
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main").java.srcDirs("src/main/kotlin")
        getByName("test").java.srcDirs("src/test/kotlin")
    }

    testOptions {
        // Las pruebas son de JVM: lo que tocan no es de Android salvo org.json,
        // que va de verdad (abajo).
        unitTests.isReturnDefaultValues = true
    }
}

// Si cambia algo aquí, cambiarlo también en cliente/flutter/android/build.gradle.kts:
// el plugin de Flutter compila estas mismas fuentes.
dependencies {
    // El WebSocket de avisos y las descargas.
    implementation("com.squareup.okhttp3:okhttp:4.12.0")

    testImplementation("junit:junit:4.13.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // En las pruebas de JVM el org.json de android.jar es un esqueleto vacío.
    testImplementation("org.json:json:20240303")
}
