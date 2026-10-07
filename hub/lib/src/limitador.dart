/// Freno por IP para las rutas donde adivinar sale barato (login, registro)
/// y para las públicas que cualquiera puede martillar (la consulta de versión).
///
/// Es una cubeta en memoria, no un Redis. Si el hub corre en varios procesos
/// cada uno lleva la suya, lo que basta para lo que esto frena —un script
/// probando claves— y no obliga a instalar nada más.
class Limitador {
  Limitador({this.cupo = 10, this.ventana = const Duration(minutes: 1)});

  final int cupo;
  final Duration ventana;
  final Map<String, List<DateTime>> _intentos = {};

  /// True si el intento cabe; false si hay que responder 429.
  bool cabe(String llave) {
    final ahora = DateTime.now();
    final desde = ahora.subtract(ventana);
    final lista = _intentos.putIfAbsent(llave, () => [])
      ..removeWhere((t) => t.isBefore(desde));
    if (lista.length >= cupo) return false;
    lista.add(ahora);
    if (_intentos.length > 10000) _limpia(desde);
    return true;
  }

  void olvida(String llave) => _intentos.remove(llave);

  void _limpia(DateTime desde) {
    _intentos.removeWhere((_, v) {
      v.removeWhere((t) => t.isBefore(desde));
      return v.isEmpty;
    });
  }
}
