import 'dart:async';

import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// El lado de Android es la biblioteca (cliente/android, con sus pruebas de
/// JVM). Aquí se prueba el puente: qué le pide Dart y qué hace con lo que le
/// llega.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const canal = MethodChannel('apk_server');
  final mensajero = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> llamadas;
  late String resultadoInstalar;
  Completer<void>? soltarInstalar;

  setUp(() {
    llamadas = [];
    resultadoInstalar = 'instalada';
    soltarInstalar = null;
    mensajero.setMockMethodCallHandler(canal, (c) async {
      llamadas.add(c);
      switch (c.method) {
        case 'configurar':
          return {
            'hub': 'https://apk.ejemplo.com',
            'app': 'inventario',
            'urlInstalar': 'https://apk.ejemplo.com/i/inventario',
            'instalacion': 'clave1234',
            'estado': {'fase': 'al_dia'},
          };
        case 'instalar':
          await soltarInstalar?.future;
          return {'resultado': resultadoInstalar};
        case 'sinPreguntar':
          return true;
      }
      return null;
    });
  });

  tearDown(() => mensajero.setMockMethodCallHandler(canal, null));

  /// Lo que mandaría Android.
  Future<Object?> desdeAndroid(String metodo, [Object? args]) async {
    final c = Completer<Object?>();
    await mensajero.handlePlatformMessage(
      'apk_server',
      const StandardMethodCodec().encodeMethodCall(MethodCall(metodo, args)),
      (r) => c.complete(r == null ? null : const StandardMethodCodec().decodeEnvelope(r)),
    );
    return c.future;
  }

  Map<String, Object?> listo(int build) => {
        'fase': 'listo',
        'version': '1.$build.0',
        'build': build,
        'apk': '/cache/apk-server/inventario_$build.apk',
        'progreso': 1.0,
      };

  Iterable<MethodCall> de(String metodo) => llamadas.where((c) => c.method == metodo);

  test('le pasa los ajustes a Android y queda con el hub del manifiesto', () async {
    final s = UpdateService(intervaloSondeo: const Duration(minutes: 30), avisos: false);
    await s.iniciar();
    final c = de('configurar').single;
    expect(c.arguments, containsPair('avisos', false));
    expect(c.arguments, containsPair('intervaloMs', 1800000));
    expect(c.arguments, containsPair('esperasMs', [5000, 15000, 30000, 60000, 120000, 300000]));
    expect((c.arguments as Map).containsKey('hub'), isFalse, reason: 'el del manifiesto');
    expect(de('iniciar'), hasLength(1));
    expect(s.hub, 'https://apk.ejemplo.com');
    expect(s.appId, 'inventario');
    expect(s.urlInstalar, 'https://apk.ejemplo.com/i/inventario');
    await s.iniciar();
    expect(de('configurar'), hasLength(1), reason: 'se configura una vez');
  });

  test('servidor y app, si se dan, pisan los del manifiesto', () async {
    final s = UpdateService(servidor: 'https://otro', app: 'otra');
    await s.iniciar();
    expect(de('configurar').single.arguments, containsPair('hub', 'https://otro'));
    expect(de('configurar').single.arguments, containsPair('app', 'otra'));
  });

  test('el estado que manda Android llega al ValueNotifier', () async {
    final s = UpdateService();
    await s.iniciar();
    await desdeAndroid('estado', {'fase': 'descargando', 'progreso': 0.4, 'version': '1.84.0', 'build': 84});
    expect(s.estado.value.fase, UpdateFase.descargando);
    expect(s.estado.value.progreso, 0.4);
    expect(s.estado.value.version, '1.84.0');
    await desdeAndroid('estado', {'fase': 'error', 'version': '1.84.0', 'progreso': 0.4, 'error': 'cortada'});
    expect(s.estado.value.fase, UpdateFase.error);
    await desdeAndroid('estado', {'fase': 'esperando_wifi', 'version': '1.84.0'});
    expect(s.estado.value.fase, UpdateFase.idle, reason: 'nada que hacer para la persona');
    await desdeAndroid('estado', {...listo(84), 'falta': 'permiso'});
    expect(s.estado.value.fase, UpdateFase.listo);
    expect(s.estado.value.apkPath, '/cache/apk-server/inventario_84.apk');
    expect(s.estado.value.falta, 'permiso');
  });

  test('Android pide el contexto y recibe el de la app', () async {
    var usuario = 'ana';
    final s = UpdateService(contexto: () => {'usuario': usuario, 'sesion': true});
    await s.iniciar();
    final r = await desdeAndroid('contexto');
    expect(r, {'usuario': 'ana', 'sesion': true});
    usuario = 'luis';
    expect(await desdeAndroid('contexto'), {'usuario': 'luis', 'sesion': true});
  });

  test('verificarYDescargar(forzar) es a pedido', () async {
    final s = UpdateService();
    await s.verificarYDescargar(forzar: true);
    expect(de('verificar').single.arguments, {'forzar': true, 'manual': true});
  });

  test('el botón instala con diálogo; dos toques, una instalación', () async {
    final s = UpdateService();
    await s.iniciar();
    await desdeAndroid('estado', listo(84));
    soltarInstalar = Completer();
    final a = s.instalar();
    final b = s.instalar();
    soltarInstalar!.complete();
    await Future.wait([a, b]);
    expect(de('instalar').single.arguments, {'conDialogo': true});
  });

  test('sin APK listo, el botón no hace nada', () async {
    final s = UpdateService();
    await s.iniciar();
    await s.instalar();
    expect(de('instalar'), isEmpty);
  });

  group('autoInstalar', () {
    test('al quedar lista, instala (sin diálogo con la app detrás)', () async {
      final s = UpdateService(autoInstalar: true);
      await s.iniciar();
      await desdeAndroid('estado', listo(84));
      await pumpEventQueue();
      expect(de('instalar').single.arguments, {'conDialogo': false});
    });

    test('si la app no lo deja, no instala; después sí', () async {
      var deja = false;
      final s = UpdateService(autoInstalar: true, puedeInstalar: () => deja);
      await s.iniciar();
      await desdeAndroid('estado', listo(84));
      await pumpEventQueue();
      expect(de('instalar'), isEmpty);
      deja = true;
      await s.instalarSiListo();
      expect(de('instalar'), hasLength(1));
    });

    test('una vez por versión, salvo que no haya arrancado', () async {
      resultadoInstalar = 'hace_falta_dialogo';
      final s = UpdateService(autoInstalar: true);
      await s.iniciar();
      await desdeAndroid('estado', listo(84));
      await pumpEventQueue();
      expect(de('instalar'), hasLength(1));
      // No arrancó: se puede volver a intentar.
      resultadoInstalar = 'sin_respuesta';
      await s.instalarSiListo();
      expect(de('instalar'), hasLength(2));
      // Arrancó: esa versión ya no.
      await s.instalarSiListo();
      expect(de('instalar'), hasLength(2));
      // Una versión nueva, sí.
      await desdeAndroid('estado', listo(85));
      await pumpEventQueue();
      expect(de('instalar'), hasLength(3));
    });
  });

  test('sin el plugin (no es Android) no hace nada ni revienta', () async {
    mensajero.setMockMethodCallHandler(canal, null);
    final s = UpdateService(autoInstalar: true);
    await s.iniciar();
    await s.verificarYDescargar(forzar: true);
    await s.instalar();
    expect(await s.sinPreguntar(), isFalse);
    expect(s.estado.value.fase, UpdateFase.idle);
    expect(s.urlInstalar, isNull);
  });
}
