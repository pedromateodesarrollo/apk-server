import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// El WebSocket de avisos del hub (`/v1/ws?app=<slug>&instalacion=<clave>`).
///
/// Reconecta solo, con espera exponencial (1, 2, 4… hasta 32 s), y hace ping
/// cada 30 s para darse cuenta de una conexión muerta (el teléfono que pasó de
/// la Wi-Fi a los datos deja el socket viejo colgado sin avisar). Mientras está
/// abierto, el hub muestra el equipo como conectado.
///
/// No interpreta los avisos: los entrega en [eventos] (`{"tipo": "version",
/// …}`) y quien escucha decide.
class AvisosWs {
  AvisosWs({required String servidor, required this.app, this.instalacion})
      : servidor = servidor.trim().replaceAll(RegExp(r'/+$'), '');

  final String servidor;
  final String app;
  final String? instalacion;

  WebSocket? _ws;
  bool _abriendo = false;
  bool _cerrado = true;
  int _reintentos = 0;
  Timer? _reconexion;

  final _eventos = StreamController<Map<String, dynamic>>.broadcast();
  final _estado = StreamController<bool>.broadcast();

  /// Lo que manda el hub: `{tipo, app, build, requerido}`.
  Stream<Map<String, dynamic>> get eventos => _eventos.stream;

  /// `true` al conectar, `false` al caerse.
  Stream<bool> get estado => _estado.stream;

  bool get conectado => _ws != null;

  Uri get uri {
    final base = Uri.parse(servidor);
    return base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '${base.path}/v1/ws',
      queryParameters: {
        'app': app,
        if (instalacion != null && instalacion!.isNotEmpty) 'instalacion': instalacion!,
      },
    );
  }

  /// Conecta y se queda reconectando hasta [cerrar]. Idempotente.
  void conectar() {
    _cerrado = false;
    unawaited(_abrir());
  }

  /// Si está esperando para reintentar, reintenta ya. Para colgarlo de «la app
  /// volvió al frente»: el teléfono pudo pasar una hora dormido.
  void reconectarAhora() {
    if (_cerrado || _ws != null) return;
    _reconexion?.cancel();
    _reintentos = 0;
    unawaited(_abrir());
  }

  Future<void> _abrir() async {
    if (_cerrado || _abriendo || _ws != null) return;
    _abriendo = true;
    try {
      final ws = await WebSocket.connect(uri.toString());
      _abriendo = false;
      if (_cerrado) {
        unawaited(ws.close());
        return;
      }
      ws.pingInterval = const Duration(seconds: 30);
      _ws = ws;
      _reintentos = 0;
      _estado.add(true);
      ws.listen(
        _alLlegar,
        onDone: () => _alCaer(ws),
        onError: (_) => _alCaer(ws),
        cancelOnError: true,
      );
    } catch (_) {
      _abriendo = false;
      _programa();
    }
  }

  void _alLlegar(dynamic crudo) {
    if (crudo is! String) return;
    try {
      final d = jsonDecode(crudo);
      if (d is Map) _eventos.add(Map<String, dynamic>.from(d));
    } catch (_) {}
  }

  void _alCaer(WebSocket ws) {
    if (!identical(ws, _ws)) return;
    _ws = null;
    _estado.add(false);
    _programa();
  }

  void _programa() {
    if (_cerrado) return;
    _reconexion?.cancel();
    final espera = Duration(seconds: min(32, 1 << min(_reintentos, 5)));
    _reintentos++;
    _reconexion = Timer(espera, () => unawaited(_abrir()));
  }

  Future<void> cerrar() async {
    _cerrado = true;
    _reconexion?.cancel();
    final ws = _ws;
    _ws = null;
    if (ws != null) {
      _estado.add(false);
      try {
        await ws.close();
      } catch (_) {}
    }
  }

  Future<void> dispose() async {
    await cerrar();
    await _eventos.close();
    await _estado.close();
  }
}
