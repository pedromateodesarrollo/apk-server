import 'dart:io';

import 'package:apk_server/publicar.dart';

/// `dart run apk_server_flutter:publicar` desde la carpeta de la app: sube el
/// APK al hub y a la app que dice su manifiesto (ver --help).
Future<void> main(List<String> args) async {
  exitCode = await publicarCli(args);
}
