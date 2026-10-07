/// apk-server — hub.
///
/// Junta las piezas: base de datos, almacén de APK en disco, REST, WebSocket
/// de las apps instaladas y el panel web. Un solo proceso; el que se
/// auto-hospeda no tiene que orquestar nada.
library;

import 'dart:io';

import 'src/almacen.dart';
import 'src/config.dart';
import 'src/db.dart';
import 'src/http/rutas_apps.dart';
import 'src/http/rutas_auth.dart';
import 'src/http/rutas_llaves.dart';
import 'src/http/rutas_publicas.dart';
import 'src/http/servidor.dart';
import 'src/log.dart';
import 'src/ws/avisos.dart';

export 'src/apk_info.dart';
export 'src/config.dart';
export 'src/db.dart';
export 'src/log.dart';

class Hub {
  Hub._(this.config, this.bd, this._servidor, this._http);

  final Config config;
  final Bd bd;
  final Servidor _servidor;
  final HttpServer _http;

  int get puerto => _http.port;
  Servidor get servidor => _servidor;

  static Future<Hub> arranca(Config config, {String migraciones = 'migraciones'}) async {
    final bd = await Bd.abrir(config.urlBd);
    await bd.migrar(migraciones);

    final almacen = Almacen(config.rutaArchivos)..prepara();
    final avisos = Avisos(bd);
    final servidor = Servidor(config, bd);

    servidor.upgrades.add(avisos.upgrade);
    registraRutasAuth(servidor);
    registraRutasLlaves(servidor);
    // Las públicas antes que las del panel: `GET /v1/apps/:app` es la ficha
    // pública y tiene que casar antes que nada que se le parezca.
    registraRutasPublicas(servidor, almacen, avisos);
    registraRutasApps(servidor, almacen, avisos);

    // Al arrancar no hay ningún socket: lo que diga la base es de antes del
    // reinicio. Se limpia para no enseñar equipos fantasma como conectados.
    await bd.ejecuta('update apk.instalacion set conectado = false where conectado');

    final http = await servidor.escuchar();
    log.info('hub', 'escuchando en ${config.host}:${http.port}');
    if (config.secretoEfimero) {
      log.aviso(
        'hub',
        'APK_SECRETO_JWT no está definida: se generó una al vuelo, '
        'así que un reinicio cierra la sesión de todos. Fíjala en producción.',
      );
    }
    return Hub._(config, bd, servidor, http);
  }

  Future<void> detiene() async {
    await _http.close(force: true);
    await bd.cerrar();
  }
}
