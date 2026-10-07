/// Auto-actualización de apps Flutter con apk-server.
///
/// [UpdateService] pregunta al hub (ya, cada hora y cuando llega un aviso por
/// WebSocket), baja el APK y lo instala —sin diálogo en Android 12+ si la
/// persona ya le dio «Permitir de esta fuente» a la app—. Los widgets
/// ([UpdateBanner], [UpdateTarjeta], [UpdateAccion]) muestran el estado.
library;

export 'package:apk_server/apk_server.dart' show ApkActualizador, AvisosWs, VersionDisponible;
export 'src/update_accion.dart';
export 'src/update_banner.dart';
export 'src/update_service.dart';
export 'src/update_tarjeta.dart';
