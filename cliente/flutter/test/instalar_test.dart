import 'package:apk_server_flutter/apk_server_flutter.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cuándo se instala sin preguntar, cuándo se abre el diálogo de siempre y
/// cuándo no se hace nada. El canal nativo se simula: lo que dice Android.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const canal = MethodChannel('apk_server');
  final mensajero = binding.defaultBinaryMessenger;

  late List<String> llamadas;
  late List<String> dialogos;
  late bool sinPreguntar;
  late Map<String, Object?> respuesta;
  late UpdateFase faseAlInstalar;
  late UpdateInstalador inst;

  UpdateInstalador nuevo() {
    final i = UpdateInstalador(
      appId: 'prueba',
      abrirDialogo: (apk) async => dialogos.add(apk),
    );
    i.estado.value = const UpdateEstado(
      fase: UpdateFase.listo,
      version: '1.2.0',
      apkPath: '/tmp/prueba_1.2.0.apk',
    );
    return i;
  }

  setUp(() {
    llamadas = [];
    dialogos = [];
    sinPreguntar = true;
    respuesta = {'resultado': 'instalada'};
    faseAlInstalar = UpdateFase.idle;
    mensajero.setMockMethodCallHandler(canal, (call) async {
      llamadas.add(call.method);
      switch (call.method) {
        case 'sinPreguntar':
          return sinPreguntar;
        case 'instalar':
          faseAlInstalar = inst.estado.value.fase;
          expect(call.arguments, {'ruta': '/tmp/prueba_1.2.0.apk'});
          return respuesta;
      }
      return null;
    });
    inst = nuevo();
  });

  tearDown(() => mensajero.setMockMethodCallHandler(canal, null));

  test('sin preguntar: queda «instalando» y no abre el diálogo', () async {
    expect(await inst.instalar(), isTrue);
    expect(faseAlInstalar, UpdateFase.instalando);
    expect(inst.estado.value.fase, UpdateFase.instalando);
    expect(dialogos, isEmpty);
  });

  for (final r in ['confirmar', 'permiso', 'no_soportado', 'error']) {
    test('$r: vuelve a «listo» y abre el diálogo de siempre', () async {
      respuesta = {'resultado': r};
      expect(await inst.instalar(), isTrue);
      expect(dialogos, ['/tmp/prueba_1.2.0.apk']);
      expect(inst.estado.value.fase, UpdateFase.listo);
      expect(inst.estado.value.apkPath, '/tmp/prueba_1.2.0.apk');
    });
  }

  test('sin diálogo y Android pide confirmar: no hace nada', () async {
    respuesta = {'resultado': 'confirmar'};
    expect(await inst.instalar(conDialogo: false), isFalse);
    expect(dialogos, isEmpty);
    expect(inst.estado.value.fase, UpdateFase.listo);
  });

  test('sin diálogo y sin permiso: ni copia el APK', () async {
    sinPreguntar = false;
    expect(await inst.instalar(conDialogo: false), isFalse);
    expect(llamadas, ['sinPreguntar']);
    expect(inst.estado.value.fase, UpdateFase.listo);
  });

  test('sin el plugin (no es Android): el diálogo de siempre', () async {
    mensajero.setMockMethodCallHandler(canal, null);
    expect(await inst.instalar(), isTrue);
    expect(dialogos, ['/tmp/prueba_1.2.0.apk']);
  });

  test('dos toques seguidos arman una sola instalación', () async {
    final a = inst.instalar();
    final b = inst.instalar();
    expect(await Future.wait([a, b]), [true, true]);
    expect(llamadas.where((m) => m == 'instalar'), hasLength(1));
  });

  test('sin APK no hace nada', () async {
    inst.estado.value = const UpdateEstado();
    expect(await inst.instalar(), isFalse);
    expect(llamadas, isEmpty);
  });

  group('UpdateService.instalarSiListo', () {
    late UpdateService servicio;
    late bool puede;

    setUp(() {
      puede = true;
      servicio = UpdateService(
        servidor: 'http://localhost:1',
        app: 'prueba',
        autoInstalar: true,
        puedeInstalar: () => puede,
      );
      inst = servicio.instalador;
      servicio.estado.value = const UpdateEstado(
        fase: UpdateFase.listo,
        version: '1.2.0',
        apkPath: '/tmp/prueba_1.2.0.apk',
      );
    });

    tearDown(() => servicio.dispose());

    test('si la app no lo deja, no instala', () async {
      puede = false;
      await servicio.instalarSiListo();
      expect(llamadas, isEmpty);
    });

    test('con la app detrás instala sin preguntar', () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await servicio.instalarSiListo();
      expect(llamadas, ['sinPreguntar', 'instalar']);
      expect(servicio.estado.value.fase, UpdateFase.instalando);
    });

    test('con la app detrás y sin permiso, espera y reintenta después',
        () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      sinPreguntar = false;
      await servicio.instalarSiListo();
      expect(llamadas, ['sinPreguntar']);
      expect(servicio.estado.value.fase, UpdateFase.listo);
      // No quedó marcada como «ya lanzada»: la próxima vez lo vuelve a intentar.
      sinPreguntar = true;
      await servicio.instalarSiListo();
      expect(llamadas, ['sinPreguntar', 'sinPreguntar', 'instalar']);
    });

    test('una vez por versión', () async {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      // Android no contestó: la instalación arrancó y el APK vuelve a «listo».
      respuesta = {'resultado': 'sin_respuesta'};
      await servicio.instalarSiListo();
      expect(servicio.estado.value.fase, UpdateFase.listo);
      await servicio.instalarSiListo();
      expect(llamadas.where((m) => m == 'instalar'), hasLength(1));
    });
  });
}
