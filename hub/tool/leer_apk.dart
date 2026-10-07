import 'dart:convert';
import 'dart:io';

import 'package:apk_server_hub/src/apk_info.dart';

/// Lo que el hub ve dentro de un APK: `dart run tool/leer_apk.dart <archivo.apk>`.
Future<void> main(List<String> args) async {
  for (final a in args) {
    final info = await ApkInfo.deArchivo(File(a));
    stdout.writeln('$a ${jsonEncode(info.aJson())}');
  }
}
