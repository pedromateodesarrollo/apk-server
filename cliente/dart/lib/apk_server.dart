/// Cliente de apk-server: el protocolo, sin plataforma encima.
///
/// [ApkActualizador] sabe preguntar «tengo la build N, ¿hay algo?» y enterarse
/// por WebSocket de que se publicó una versión. NO descarga ni instala: eso es
/// de la plataforma (en Flutter, el paquete `apk_server_flutter`).
library;

export 'src/actualizador.dart';
export 'src/avisos.dart';
export 'src/version.dart';
