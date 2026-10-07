import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../db.dart';
import '../log.dart';

/// El WebSocket de las apps instaladas: `GET /v1/ws?app=<slug>&instalacion=<clave>`.
///
/// Sirve para dos cosas. Una, que una versión publicada llegue al instante en
/// vez de esperar al sondeo de cada hora: al publicar, el hub manda
/// `{"tipo":"version", …}` a los sockets de esa app y cada una pregunta. Dos,
/// saber qué equipos están vivos: mientras el socket de una instalación está
/// abierto, su fila dice `conectado`, y al cerrarse queda la hora en que se vio
/// por última vez.
///
/// Sin credencial, como la consulta de versión: lo que se reparte por aquí es
/// «salió la build 84», que ya es público. La `clave` solo marca la fila de
/// esa instalación; no da acceso a nada.
class Avisos {
  Avisos(this.bd);

  final Bd bd;

  /// Topes para que nadie abra cien mil sockets: no hay token que lo frene.
  static const maxTotal = 10000;
  static const maxPorIp = 300;

  final Map<String, Set<WebSocket>> _porApp = {};
  final Map<String, int> _porIp = {};

  /// Sockets vivos por instalación (`<app>:<clave>`). Una app puede abrir dos
  /// al reconectar; la fila solo pasa a desconectada cuando se cierra el
  /// último.
  final Map<String, int> _vivas = {};
  int _total = 0;

  int get total => _total;
  int conectados(String slug) => _porApp[slug]?.length ?? 0;

  /// Manejador de upgrade para [Servidor.upgrades]. Devuelve true si la
  /// petición era suya (la haya aceptado o no).
  Future<bool> upgrade(HttpRequest pet) async {
    if (pet.uri.path != '/v1/ws') return false;
    final res = pet.response;
    if (!WebSocketTransformer.isUpgradeRequest(pet)) {
      res.statusCode = HttpStatus.badRequest;
      res.write('Esta ruta es un WebSocket');
      await res.close();
      return true;
    }
    final slug = pet.uri.queryParameters['app']?.trim() ?? '';
    final clave = (pet.uri.queryParameters['instalacion'] ?? '').trim();
    final app = slug.isEmpty
        ? null
        : await bd.fila('select id from apk.app where slug = @s', {'s': slug});
    if (app == null) {
      res.statusCode = HttpStatus.notFound;
      res.write('No hay una app «$slug»');
      await res.close();
      return true;
    }
    final ip = pet.headers.value('x-real-ip')?.trim() ??
        pet.connectionInfo?.remoteAddress.address ??
        '';
    if (_total >= maxTotal || (_porIp[ip] ?? 0) >= maxPorIp) {
      res.statusCode = HttpStatus.serviceUnavailable;
      res.write('Demasiadas conexiones');
      await res.close();
      return true;
    }

    final WebSocket ws;
    try {
      ws = await WebSocketTransformer.upgrade(pet);
    } catch (e) {
      log.aviso('ws', 'upgrade falló: $e');
      return true;
    }
    // Ping de protocolo: detecta el teléfono que se fue sin cerrar (sin señal,
    // apagado) y mantiene abierto el camino a través de nginx y de NAT.
    ws.pingInterval = const Duration(seconds: 30);

    final appId = app['id'] as int;
    final vivaClave = clave.isNotEmpty && clave.length <= 100 ? '$slug:$clave' : null;
    _total++;
    _porIp[ip] = (_porIp[ip] ?? 0) + 1;
    _porApp.putIfAbsent(slug, () => <WebSocket>{}).add(ws);
    if (vivaClave != null) {
      _vivas[vivaClave] = (_vivas[vivaClave] ?? 0) + 1;
      unawaited(_marca(appId, clave, conectado: true));
    }

    var cerrado = false;
    void cierra() {
      if (cerrado) return;
      cerrado = true;
      _total--;
      final n = (_porIp[ip] ?? 1) - 1;
      if (n <= 0) {
        _porIp.remove(ip);
      } else {
        _porIp[ip] = n;
      }
      final set = _porApp[slug];
      set?.remove(ws);
      if (set != null && set.isEmpty) _porApp.remove(slug);
      if (vivaClave != null) {
        final v = (_vivas[vivaClave] ?? 1) - 1;
        if (v <= 0) {
          _vivas.remove(vivaClave);
          unawaited(_marca(appId, clave, conectado: false));
        } else {
          _vivas[vivaClave] = v;
        }
      }
    }

    ws.listen(
      (m) {
        // Keepalive de aplicación, para clientes que no pueden mandar ping de
        // protocolo (un navegador).
        if (m is String && m.contains('"ping"')) {
          try {
            ws.add('{"tipo":"pong"}');
          } catch (_) {}
        }
      },
      onDone: cierra,
      onError: (_) => cierra(),
      cancelOnError: true,
    );
    ws.add(jsonEncode({'tipo': 'hola', 'app': slug}));
    return true;
  }

  /// Avisa a todas las instalaciones conectadas de [slug]. Devuelve a cuántas.
  int anuncia(String slug, Map<String, Object?> datos) {
    final set = _porApp[slug];
    if (set == null || set.isEmpty) return 0;
    final frame = jsonEncode({'tipo': 'version', 'app': slug, ...datos});
    var n = 0;
    for (final ws in set.toList()) {
      try {
        ws.add(frame);
        n++;
      } catch (_) {}
    }
    return n;
  }

  Future<void> _marca(int app, String clave, {required bool conectado}) async {
    try {
      await bd.ejecuta(
        '''update apk.instalacion set conectado = @c, ultima_vez = now()
            where app = @a and clave = @k''',
        {'c': conectado, 'a': app, 'k': clave},
      );
    } catch (e) {
      log.aviso('ws', 'no se pudo marcar la instalación: $e');
    }
  }
}
