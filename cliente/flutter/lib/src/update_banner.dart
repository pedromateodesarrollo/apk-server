import 'package:flutter/material.dart';

import 'update_service.dart';

/// Banner de actualización listo para colgar en `Scaffold.bottomNavigationBar`.
/// Reacciona al estado del [UpdateService]. Oculto en reposo.
///
/// CALLADO MIENTRAS DESCARGA, a propósito. Antes pintaba «Descargando… 37%»
/// durante toda la bajada, y eso es una barra que se come sitio y llama la
/// atención para pedir algo que el usuario no tiene que hacer: la descarga va
/// sola, en segundo plano, y puede tardar. Un aviso solo se gana la pantalla
/// cuando hay una decisión que tomar — y aquí la hay una sola vez, al final:
/// «está lista, ¿la instalo?».
///
/// [mostrarDescarga] lo devuelve para quien lo quiera (p.ej. una pantalla de
/// ajustes donde el usuario acaba de pulsar «buscar actualización» y sí espera
/// ver que pasa algo). Por defecto, no.
class UpdateBanner extends StatelessWidget {
  final UpdateService service;
  final bool mostrarDescarga;
  const UpdateBanner(this.service, {super.key, this.mostrarDescarga = false});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateEstado>(
      valueListenable: service.estado,
      builder: (context, e, _) {
        switch (e.fase) {
          case UpdateFase.descargando:
            if (!mostrarDescarga) return const SizedBox.shrink();
            return _barra(
              context,
              child: Row(children: [
                const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                        'Descargando actualización ${e.version ?? ''} '
                        '(${(e.progreso * 100).toStringAsFixed(0)}%)…')),
              ]),
            );
          case UpdateFase.instalando:
            return _barra(
              context,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(children: [
                const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 12),
                Expanded(
                    child: Text(
                        'Instalando ${e.version ?? ''}. $kUpdateTextoInstalando',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis)),
              ]),
            );
          case UpdateFase.listo:
            return _barra(
              context,
              color: Theme.of(context).colorScheme.primaryContainer,
              child: Row(children: [
                Expanded(
                    child: Text(
                        'Actualización ${e.version ?? ''} lista'
                        '${e.requerido ? ' (requerida)' : ''}.',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis)),
                FilledButton(
                    onPressed: service.instalar,
                    child: const Text('Instalar')),
              ]),
            );
          default:
            return const SizedBox.shrink();
        }
      },
    );
  }

  /// El ancho se FIJA con el de la pantalla, no se hereda.
  ///
  /// El `bottomNavigationBar` no siempre entrega una anchura acotada, y este
  /// banner lleva un `Expanded` dentro de un `Row`: sin cota en el eje
  /// principal, `Expanded` no puede repartir nada. En la TC56 eso salió primero
  /// como el texto a una letra por línea ocupando la pantalla entera, y después
  /// —al intentar arreglarlo con un `ConstrainedBox(minWidth: infinity)`, que
  /// deja `maxWidth` en infinito— como una barra vacía.
  ///
  /// `SizedBox(width: …)` impone la anchura sea cual sea la que llegue, que es
  /// lo único que lo hace inmune. El alto se queda intrínseco: la barra mide lo
  /// que mide su contenido.
  Widget _barra(BuildContext context,
          {required Widget child, Color? color}) =>
      Material(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerHighest,
        child: SizedBox(
          width: MediaQuery.sizeOf(context).width,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: child,
            ),
          ),
        ),
      );
}
