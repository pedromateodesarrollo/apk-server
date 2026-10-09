/// Auto-actualización de apps Flutter con apk-server.
///
/// [UpdateService] es el puente con la biblioteca de Android del paquete, que
/// pregunta al hub (ya, cada hora y cuando avisa por WebSocket), baja el APK
/// en segundo plano, avisa con una notificación cuando está lista y la instala
/// —sin diálogo en Android 12+ si la persona ya le dio «Permitir de esta
/// fuente» a la app—. Los widgets ([UpdateBanner], [UpdateTarjeta],
/// [UpdateAccion]) muestran el estado.
///
/// Para publicar: `dart run apk_server_flutter:publicar --apk <archivo>`.
library;

export 'src/update_accion.dart';
export 'src/update_banner.dart';
export 'src/update_service.dart';
export 'src/update_tarjeta.dart';
