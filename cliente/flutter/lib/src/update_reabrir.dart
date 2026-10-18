import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'update_service.dart';

/// La fila «Abrir sola tras actualizar» para «Acerca de» o los ajustes de la
/// app.
///
/// Al actualizarse, Android cierra la app; para que se vuelva a abrir sola
/// hace falta que la persona le dé «Mostrar sobre otras apps» (Android no deja
/// abrir una pantalla desde segundo plano sin él). Tocar la fila abre ese
/// ajuste de Android; al volver a la app, la fila dice cómo quedó.
///
/// Fuera de Android no se ve.
class UpdateReabrirSola extends StatefulWidget {
  const UpdateReabrirSola(this.service, {super.key});

  final UpdateService service;

  @override
  State<UpdateReabrirSola> createState() => _UpdateReabrirSolaState();
}

class _UpdateReabrirSolaState extends State<UpdateReabrirSola> with WidgetsBindingObserver {
  /// Null mientras pregunta.
  bool? _concedido;

  static bool get _android => !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _leer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // Volvió de los ajustes de Android: cómo quedó.
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) _leer();
  }

  Future<void> _leer() async {
    if (!_android) return;
    final v = await widget.service.reabrirSola();
    if (mounted) setState(() => _concedido = v);
  }

  Future<void> _pedir() async {
    final abrio = await widget.service.pedirReabrirSola();
    if (!abrio && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(
        content: Text('No se pudo abrir el ajuste. Búscalo en Ajustes → Aplicaciones → esta app → '
            '«Mostrar sobre otras apps».'),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_android || _concedido == null) return const SizedBox.shrink();
    final si = _concedido!;
    return SwitchListTile(
      value: si,
      onChanged: (_) => _pedir(),
      secondary: const Icon(Icons.restart_alt),
      title: const Text('Abrir sola tras actualizar'),
      subtitle: Text(si
          ? 'Al instalar una versión nueva, la app se cierra y se vuelve a abrir sola.'
          : 'Al instalar una versión nueva, la app se cierra. Para que se vuelva a abrir sola, '
              'actívalo y dale «Mostrar sobre otras apps».'),
    );
  }
}
