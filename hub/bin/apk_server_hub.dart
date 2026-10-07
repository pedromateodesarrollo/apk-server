import 'dart:io';

import 'package:apk_server_hub/hub.dart';
import 'package:apk_server_hub/src/cli.dart';

/// Punto de entrada del hub.
///
///   APK_DATABASE_URL=postgres://... apk-server-hub
///
/// Sin argumentos: migra la base si hace falta y se pone a escuchar. Con una
/// orden (`org`, `invitar`, `llave`, `migrar`), la hace y sale.
Future<void> main(List<String> args) async {
  if (args.contains('--ayuda') || args.contains('-h')) {
    stdout.writeln('apk-server-hub\n\n$ayudaCli\nVariables de entorno:\n  ${Config.ayuda}');
    return;
  }

  final Config config;
  try {
    config = Config.desdeEntorno();
  } on ArgumentError catch (e) {
    stderr.writeln(e.message);
    exitCode = 64; // EX_USAGE
    return;
  }

  final m = Platform.environment['APK_MIGRACIONES']?.trim();
  final migraciones = (m == null || m.isEmpty) ? 'migraciones' : m;

  if (args.isNotEmpty) {
    exitCode = await correCli(args, config, migraciones);
    return;
  }

  final hub = await Hub.arranca(config, migraciones: migraciones);

  // Cerrar bien importa: un SIGTERM en medio de un despliegue no debe dejar
  // conexiones abiertas contra Postgres.
  for (final senal in [ProcessSignal.sigint, ProcessSignal.sigterm]) {
    senal.watch().listen((_) async {
      log.info('hub', 'apagando…');
      await hub.detiene();
      exit(0);
    });
  }
}
