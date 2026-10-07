import 'dart:io';

/// Log a stdout, una línea por evento, con hora en UTC.
///
/// Va a stdout porque el destino real es `journalctl` o `docker logs`: quien
/// opera esto no quiere un archivo más que rotar.
///
/// **Nunca se registra un token ni una llave.** Son credenciales vivas, y el
/// log de un servicio termina en sitios que nadie audita.
///
/// Las órdenes de consola lo pasan a stderr ([logAStderr]): su stdout es el
/// resultado (un enlace, una llave) y se manda directo a un archivo.
class Log {
  const Log();

  void info(String etiqueta, String mensaje) => _linea('info', etiqueta, mensaje);
  void aviso(String etiqueta, String mensaje) => _linea('aviso', etiqueta, mensaje);
  void error(String etiqueta, String mensaje) => _linea('error', etiqueta, mensaje);

  void _linea(String nivel, String etiqueta, String mensaje) {
    final t = DateTime.now().toUtc().toIso8601String();
    (_aStderr ? stderr : stdout).writeln('$t $nivel [$etiqueta] $mensaje');
  }
}

bool _aStderr = false;
void logAStderr() => _aStderr = true;

const log = Log();
