import 'package:flutter/material.dart';

import 'update_service.dart';

/// Tarjeta de actualización para el cuerpo de una pantalla de menú. Dice con
/// palabras lo que pasa: «Bajando la actualización 1.14.1… 37 %», al terminar
/// «Actualización 1.14.1 lista» con el botón de instalar y, mientras Android
/// instala sin preguntar, que la app se va a cerrar. Si la descarga se corta,
/// lo dice también —y que sigue sola—: antes la tarjeta desaparecía y nadie
/// sabía que había una versión a medio bajar.
///
/// Sustituye al indicador de la barra de título ([UpdateAccion]) donde hay
/// sitio para una frase: un anillo de 22 px con un icono no le dice a nadie
/// que la app se está actualizando. En reposo no existe.
///
/// Pensada para pantallas que se miran de lejos y con guantes: letra grande,
/// barra de progreso ancha, un solo botón.
class UpdateTarjeta extends StatelessWidget {
  const UpdateTarjeta(this.service, {super.key});

  final UpdateService service;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<UpdateEstado>(
      valueListenable: service.estado,
      builder: (context, e, _) {
        // El error solo se enseña si es de una descarga (lleva la versión):
        // que el hub no conteste no es asunto de quien usa la app.
        if (e.fase == UpdateFase.error && e.version != null) {
          return _cortada(context, e);
        }
        if (e.fase != UpdateFase.descargando &&
            e.fase != UpdateFase.listo &&
            e.fase != UpdateFase.instalando) {
          return const SizedBox.shrink();
        }
        final c = Theme.of(context).colorScheme;
        final bajando = e.fase == UpdateFase.descargando;
        final instalando = e.fase == UpdateFase.instalando;
        final pct = (e.progreso * 100).clamp(0, 100).toStringAsFixed(0);
        final version = e.version ?? '';
        return Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
          decoration: BoxDecoration(
            color: bajando ? c.surfaceContainerHighest : c.primaryContainer,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    bajando ? Icons.downloading : Icons.system_update_alt,
                    size: 28,
                    color: bajando ? c.onSurface : c.onPrimaryContainer,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      bajando
                          ? 'Bajando la actualización $version'
                          : instalando
                              ? 'Instalando la actualización $version'
                              : 'Actualización $version lista'
                                  '${e.requerido ? ' · requerida' : ''}',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                        color: bajando ? c.onSurface : c.onPrimaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              if (instalando) ...[
                LinearProgressIndicator(
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Text(
                  kUpdateTextoInstalando,
                  style: TextStyle(fontSize: 14, color: c.onPrimaryContainer),
                ),
              ] else if (bajando) ...[
                LinearProgressIndicator(
                  value: e.progreso > 0 ? e.progreso : null,
                  minHeight: 8,
                  borderRadius: BorderRadius.circular(4),
                ),
                const SizedBox(height: 8),
                Text(
                  e.progreso > 0
                      ? '$pct % · puedes seguir trabajando, avisa cuando esté.'
                      : 'Empezando la descarga…',
                  style: TextStyle(fontSize: 14, color: c.outline),
                ),
              ] else ...[
                Text(
                  '$kUpdateTextoListo Lo que esté a medio contar ya está '
                  'guardado en el servidor.',
                  style: TextStyle(fontSize: 14, color: c.onPrimaryContainer),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: service.instalar,
                  icon: const Icon(Icons.install_mobile),
                  label: const Text('Instalar ahora'),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  /// La descarga se cortó y [UpdateService] la va a seguir solo. El botón es
  /// para no esperar el turno (la red ya volvió y se nota).
  Widget _cortada(BuildContext context, UpdateEstado e) {
    final c = Theme.of(context).colorScheme;
    final pct = (e.progreso * 100).clamp(0, 100).toStringAsFixed(0);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: c.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.wifi_off, size: 28, color: c.onSurface),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Se cortó la descarga de la actualización ${e.version}'
                  '${e.requerido ? ' · requerida' : ''}',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: c.onSurface,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (e.progreso > 0) ...[
            LinearProgressIndicator(
              value: e.progreso,
              minHeight: 8,
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 8),
          ],
          Text(
            '${e.progreso > 0 ? 'Va por el $pct %. ' : ''}'
            'Sigue sola en cuanto haya conexión, desde donde quedó; no hace '
            'falta cerrar la app.',
            style: TextStyle(fontSize: 14, color: c.outline),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => service.verificarYDescargar(forzar: true),
            icon: const Icon(Icons.refresh),
            label: const Text('Reintentar ahora'),
          ),
        ],
      ),
    );
  }
}
