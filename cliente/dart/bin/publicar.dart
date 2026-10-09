import 'dart:io';

import 'package:apk_server/publicar.dart';

/// `dart run apk_server:publicar --apk app-release.apk` (ver --help).
Future<void> main(List<String> args) async {
  exitCode = await publicarCli(args);
}
