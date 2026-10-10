import 'package:flutter/material.dart';

import 'update_service.dart';

/// Indicador de actualización para la barra de título. Va en `AppBar.actions`.
///
/// EN REPOSO NO EXISTE. Aparece solo cuando hay algo bajando o algo listo, y
/// desaparece al terminar. Es el término medio entre el banner —que ocupaba
/// sitio y pedía atención para algo que el usuario no tiene que hacer— y el
/// silencio total, donde la app se pasa cinco minutos bajando 51 MB sin que
/// nadie sepa que viene una versión nueva.
///
/// Mientras baja es un anillo de progreso pequeño; cuando está lista, un icono
/// con punto. Tocarlo abre el detalle: qué versión, cuánto lleva, y el botón de
/// instalar cuando ya se puede.
class UpdateAccion extends StatelessWidget {
  const UpdateAccion(this.service, {super.key, this.nota = ''});

  final UpdateService service;

  /// Lo que esta app quiera añadir cuando la versión está lista; ver
  /// [UpdateTarjeta.nota].
  final String nota;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateEstado>(
      valueListenable: service.estado,
      builder: (context, e, _) {
        if (e.fase != UpdateFase.descargando &&
            e.fase != UpdateFase.listo &&
            e.fase != UpdateFase.instalando) {
          return const SizedBox.shrink();
        }
        final c = Theme.of(context).colorScheme;
        final bajando = e.fase == UpdateFase.descargando;
        final instalando = e.fase == UpdateFase.instalando;
        return IconButton(
          tooltip: bajando
              ? 'Bajando la actualización ${e.version ?? ''}'
              : instalando
                  ? 'Instalando la actualización ${e.version ?? ''}'
                  : 'Actualización ${e.version ?? ''} lista',
          onPressed: () => _detalle(context, e),
          icon: bajando || instalando
              // El anillo LLEVA el porcentaje aunque no se lea de un vistazo:
              // que avance es lo que distingue «está bajando» de «se colgó».
              // Instalando no hay porcentaje: gira.
              ? SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.5,
                    value: bajando && e.progreso > 0 ? e.progreso : null,
                    color: c.onSurface,
                  ),
                )
              : Badge(
                  smallSize: 8,
                  child: const Icon(Icons.system_update_alt),
                ),
        );
      },
    );
  }

  /// El detalle. Diálogo y no pantalla: se mira, se decide y se cierra — no hay
  /// nada que recorrer.
  ///
  /// Se reconstruye con el estado en vivo: abierto durante la descarga, la
  /// barra sigue avanzando y el botón de instalar aparece solo al terminar, sin
  /// tener que cerrarlo y volver a abrirlo.
  void _detalle(BuildContext context, UpdateEstado inicial) {
    showDialog<void>(
      context: context,
      builder: (ctx) => ValueListenableBuilder<UpdateEstado>(
        valueListenable: service.estado,
        builder: (ctx, e, _) {
          final bajando = e.fase == UpdateFase.descargando;
          final instalando = e.fase == UpdateFase.instalando;
          final pct = (e.progreso * 100).clamp(0, 100).toStringAsFixed(0);
          return AlertDialog(
            title: Text(bajando
                ? 'Bajando la actualización'
                : instalando
                    ? 'Instalando la actualización'
                    : 'Actualización lista'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Versión ${e.version ?? ''}'
                    '${e.requerido ? ' · requerida' : ''}'),
                const SizedBox(height: 12),
                if (bajando) ...[
                  LinearProgressIndicator(
                    value: e.progreso > 0 ? e.progreso : null,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    e.progreso > 0
                        ? '$pct % de unos 51 MB'
                        : 'Empezando la descarga…',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.outline,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Puedes seguir trabajando: baja sola y avisa cuando esté.',
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.outline,
                      fontSize: 13,
                    ),
                  ),
                ] else if (instalando) ...[
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    kUpdateTextoInstalando,
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.outline,
                      fontSize: 13,
                    ),
                  ),
                ] else
                  Text(
                    updateTextoListo(nota),
                    style: TextStyle(
                      color: Theme.of(ctx).colorScheme.outline,
                      fontSize: 13,
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(bajando || instalando ? 'Cerrar' : 'Ahora no'),
              ),
              if (!bajando && !instalando)
                FilledButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    service.instalar();
                  },
                  child: const Text('Instalar'),
                ),
            ],
          );
        },
      ),
    );
  }
}
