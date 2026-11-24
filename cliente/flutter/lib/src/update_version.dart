import 'package:flutter/material.dart';

import 'update_service.dart';

/// La versión instalada, a la vista («v1.3.7»): quien tenga el equipo delante
/// sabe si está al día sin abrir Ajustes. Para la esquina de todas las
/// pantallas (un `Stack` en el `builder:` de MaterialApp, con
/// [UpdateVersion.esquina]) o un encabezado. No recibe toques.
class UpdateVersion extends StatefulWidget {
  final UpdateService service;

  /// Con la build entre paréntesis («v1.3.7 (81)»).
  final bool conBuild;
  final TextStyle? estilo;
  const UpdateVersion(this.service, {super.key, this.conBuild = false, this.estilo});

  /// Pastilla abajo a la izquierda, por encima de todo, sin tapar toques.
  static Widget esquina(UpdateService service, {bool conBuild = false}) => Positioned(
        left: 6,
        bottom: 6,
        child: IgnorePointer(
          child: SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(8),
              ),
              child: UpdateVersion(
                service,
                conBuild: conBuild,
                estilo: const TextStyle(
                    color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700, decoration: TextDecoration.none),
              ),
            ),
          ),
        ),
      );

  @override
  State<UpdateVersion> createState() => _UpdateVersionState();
}

class _UpdateVersionState extends State<UpdateVersion> {
  ({String version, int build})? _v;

  @override
  void initState() {
    super.initState();
    widget.service.versionInstalada().then((v) {
      if (mounted) setState(() => _v = v);
    });
  }

  @override
  Widget build(BuildContext context) {
    final v = _v;
    if (v == null || v.version.isEmpty) return const SizedBox.shrink();
    return Text(widget.conBuild ? 'v${v.version} (${v.build})' : 'v${v.version}', style: widget.estilo);
  }
}
