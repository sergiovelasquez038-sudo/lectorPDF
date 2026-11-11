import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Comunicación con el código Android propio de la app (MainActivity.kt):
/// abrir archivos desde otras apps, ajustes de voz, servicio de lectura
/// con la pantalla apagada y mantener la pantalla encendida.
class SystemBridge {
  SystemBridge._();

  static const _channel = MethodChannel('lector/system');

  /// Otra app (WhatsApp, Gmail, Archivos…) nos envió un documento.
  static VoidCallback? onFileOpened;

  /// Botones de la notificación de lectura.
  static VoidCallback? onReadingToggle;
  static VoidCallback? onReadingStop;

  static void init() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'fileOpened':
          onFileOpened?.call();
        case 'ttsToggle':
          onReadingToggle?.call();
        case 'ttsStop':
          onReadingStop?.call();
      }
      return null;
    });
  }

  static Future<T?> _invoke<T>(String method, [Object? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('SystemBridge.$method: $e');
      return null;
    }
  }

  static Future<String?> takeOpenedFile() => _invoke<String>('takeOpenedFile');

  /// Carpeta donde se guardan los archivos recibidos de otras apps.
  static Future<String?> receivedDir() => _invoke<String>('receivedDir');

  static Future<void> keepScreenOn(bool on) => _invoke<void>('keepScreenOn', on);

  static Future<bool> openTtsSettings() async =>
      await _invoke<bool>('openTtsSettings') ?? false;

  /// Abre la pantalla para descargar voces de un motor (p. ej. Google).
  static Future<bool> installTtsData(String engine) async =>
      await _invoke<bool>('installTtsData', engine) ?? false;

  static Future<bool> openUrl(String url) async =>
      await _invoke<bool>('openUrl', url) ?? false;

  static Future<bool> openStore(String package) async =>
      await _invoke<bool>('openStore', package) ?? false;

  /// Muestra la notificación de lectura y mantiene viva la app
  /// para seguir leyendo con la pantalla apagada.
  static Future<void> startReading(String title) =>
      _invoke<void>('startReading', {'title': title});

  static Future<void> updateReading(String title, bool playing) =>
      _invoke<void>('updateReading', {'title': title, 'playing': playing});

  static Future<void> stopReading() => _invoke<void>('stopReading');
}
