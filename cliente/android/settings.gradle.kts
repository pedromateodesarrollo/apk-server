// Para compilar y probar la biblioteca sola:
//
//   cd cliente/android && ./gradlew test assembleRelease
//
// Dentro de otra app no se usa este archivo: ahí la biblioteca entra como un
// proyecto más (`include(":apk-server")` con su `projectDir`) y las versiones
// de los plugins las pone la app. Ver README.md.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library") version "9.1.0" apply false
    id("org.jetbrains.kotlin.android") version "2.4.0" apply false
}

rootProject.name = "apk-server-android"
