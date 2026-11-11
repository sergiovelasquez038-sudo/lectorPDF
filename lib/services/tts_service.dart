import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Una voz instalada en el teléfono.
class TtsVoice {
  const TtsVoice({
    required this.name,
    required this.locale,
    this.quality = '',
    this.network = false,
    this.installed = true,
  });

  final String name;
  final String locale;
  final String quality;

  /// Las voces "online" de Google suenan más naturales pero usan internet.
  final bool network;

  /// false si la voz aparece pero falta descargarla.
  final bool installed;

  bool get highQuality => quality == 'very high' || quality == 'high';

  String get language => locale.split(RegExp('[-_]')).first.toLowerCase();

  /// Código corto de la voz, p. ej. "esd" en "es-us-x-esd-local".
  String get variant {
    final m = RegExp(r'-x-([a-z0-9]+)(?:-|$)').firstMatch(name.toLowerCase());
    if (m != null) return m.group(1)!;
    if (name.toLowerCase().endsWith('-language')) return '';
    return name;
  }

  Map<String, String> toMap() => {'name': name, 'locale': locale};

  static TtsVoice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name']?.toString();
    final locale = raw['locale']?.toString();
    if (name == null || locale == null || name.isEmpty) return null;
    final features = raw['features']?.toString() ?? '';
    return TtsVoice(
      name: name,
      locale: locale,
      quality: raw['quality']?.toString() ?? '',
      network: raw['network_required']?.toString() == '1',
      installed: !features.split('\t').contains('notInstalled'),
    );
  }
}

const kGoogleTts = 'com.google.android.tts';
const kSherpaTts = 'org.woheller69.ttsengine';

/// Nombre amigable de un motor de voz instalado.
String engineLabel(String package) => switch (package) {
      kGoogleTts => 'Google',
      'com.samsung.SMT' => 'Samsung',
      kSherpaTts => 'SherpaTTS (neuronal)',
      'com.github.olga_yakovleva.rhvoice.android' => 'RHVoice',
      'com.reecedunn.espeak' || 'com.googlecode.eyesfree.espeak' => 'eSpeak',
      'com.svox.pico' => 'Pico',
      _ => package.split('.').last,
    };

/// Maneja el motor de voz de Android: elegir motor y voz, velocidad, tono,
/// y leer un trozo de texto avisando cada palabra.
class TtsService extends ChangeNotifier {
  TtsService._();
  static final TtsService instance = TtsService._();

  SharedPreferences? _prefs;
  FlutterTts? _tts;
  Future<void>? _ready;

  String? engine;
  String? voiceName;
  String? voiceLocale;
  double speed = 1.0;
  double pitch = 1.0;

  Completer<bool>? _pending;
  bool _started = false;
  void Function(int start, int end)? _onWord;
  Timer? _watchdog;

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    engine = prefs.getString('tts_engine');
    voiceName = prefs.getString('tts_voice_name');
    voiceLocale = prefs.getString('tts_voice_locale');
    speed = prefs.getDouble('tts_speed') ?? 1.0;
    pitch = prefs.getDouble('tts_pitch') ?? 1.0;
  }

  Future<FlutterTts> _ensure() async {
    _ready ??= _init();
    await _ready;
    return _tts!;
  }

  Future<void> _init() async {
    final tts = FlutterTts();
    _tts = tts;
    tts.setStartHandler(() => _started = true);
    tts.setCompletionHandler(() {
      if (_started) _finish(true);
    });
    tts.setErrorHandler((message) {
      debugPrint('Error de voz: $message');
      _finish(false);
    });
    tts.setProgressHandler((text, start, end, word) => _onWord?.call(start, end));
    try {
      final saved = engine;
      if (saved != null) {
        final installed = await _enginesOf(tts);
        if (installed.contains(saved)) {
          await tts.setEngine(saved);
        } else {
          engine = null;
        }
      }
      await _applySettings(tts);
    } catch (e) {
      debugPrint('No se pudo preparar la voz: $e');
    }
  }

  Future<void> _applySettings(FlutterTts tts) async {
    // flutter_tts usa 0.5 como velocidad normal en Android.
    await tts.setSpeechRate((speed * 0.5).clamp(0.05, 1.5).toDouble());
    await tts.setPitch(pitch.clamp(0.5, 2.0).toDouble());
    final name = voiceName;
    final locale = voiceLocale;
    if (name != null && locale != null) {
      await tts.setVoice({'name': name, 'locale': locale});
    }
  }

  static Future<List<String>> _enginesOf(FlutterTts tts) async {
    try {
      final raw = await tts.getEngines;
      if (raw is List) return raw.map((e) => e.toString()).toList();
    } catch (e) {
      debugPrint('getEngines: $e');
    }
    return const [];
  }

  // ---------- Motores y voces ----------

  Future<List<String>> engines() async => _enginesOf(await _ensure());

  Future<String?> defaultEngine() async {
    try {
      final r = await (await _ensure()).getDefaultEngine;
      return r?.toString();
    } catch (_) {
      return null;
    }
  }

  Future<bool> selectEngine(String package) async {
    final tts = await _ensure();
    await stop();
    try {
      await tts.setEngine(package);
    } catch (e) {
      debugPrint('No se pudo usar el motor $package: $e');
      return false;
    }
    engine = package;
    voiceName = null;
    voiceLocale = null;
    final prefs = _prefs;
    if (prefs != null) {
      await prefs.setString('tts_engine', package);
      await prefs.remove('tts_voice_name');
      await prefs.remove('tts_voice_locale');
    }
    try {
      await _applySettings(tts);
    } catch (_) {}
    notifyListeners();
    return true;
  }

  Future<List<TtsVoice>> voices() async {
    try {
      final raw = await (await _ensure()).getVoices;
      if (raw is List) {
        return raw.map(TtsVoice.fromMap).whereType<TtsVoice>().toList();
      }
    } catch (e) {
      debugPrint('getVoices: $e');
    }
    return const [];
  }

  bool isSelected(TtsVoice v) => v.name == voiceName && v.locale == voiceLocale;

  /// true si el usuario ya eligió una voz.
  bool get hasChosenVoice => voiceName != null;

  /// true si ya le mostramos la pantalla para elegir voz.
  bool get voicePrompted => _prefs?.getBool('tts_voice_prompted') ?? false;

  Future<void> markVoicePrompted() async {
    await _prefs?.setBool('tts_voice_prompted', true);
    notifyListeners();
  }

  Future<void> selectVoice(TtsVoice v) async {
    final tts = await _ensure();
    voiceName = v.name;
    voiceLocale = v.locale;
    final prefs = _prefs;
    if (prefs != null) {
      await prefs.setString('tts_voice_name', v.name);
      await prefs.setString('tts_voice_locale', v.locale);
    }
    try {
      await tts.setVoice(v.toMap());
    } catch (e) {
      debugPrint('setVoice: $e');
    }
    notifyListeners();
  }

  Future<void> setSpeed(double value) async {
    speed = value;
    notifyListeners();
    await _prefs?.setDouble('tts_speed', value);
    final tts = _tts;
    if (tts != null) {
      await tts.setSpeechRate((value * 0.5).clamp(0.05, 1.5).toDouble());
    }
  }

  Future<void> setPitch(double value) async {
    pitch = value;
    notifyListeners();
    await _prefs?.setDouble('tts_pitch', value);
    final tts = _tts;
    if (tts != null) await tts.setPitch(value.clamp(0.5, 2.0).toDouble());
  }

  // ---------- Hablar ----------

  /// Lee [text] y termina cuando la voz acaba (true) o falla (false).
  /// [onWord] recibe la posición de cada palabra dentro de [text].
  Future<bool> speakChunk(String text,
      {void Function(int start, int end)? onWord}) async {
    final tts = await _ensure();
    _finish(false);
    final completer = Completer<bool>();
    _pending = completer;
    _started = false;
    _onWord = onWord;
    // Si la voz ni siquiera empieza en 15 s, algo falló: seguimos adelante.
    _watchdog = Timer(const Duration(seconds: 15), () {
      if (!_started && identical(_pending, completer)) _finish(false);
    });
    try {
      await tts.speak(text);
    } catch (e) {
      debugPrint('speak: $e');
      _finish(false);
    }
    return completer.future;
  }

  void _finish(bool ok) {
    final c = _pending;
    _pending = null;
    _onWord = null;
    _watchdog?.cancel();
    _watchdog = null;
    if (c != null && !c.isCompleted) c.complete(ok);
  }

  Future<void> stop() async {
    _finish(false);
    final tts = _tts;
    if (tts == null) return;
    try {
      await tts.stop();
    } catch (_) {}
  }
}

/// "1x", "1.25x", "0.8x"
String formatSpeed(double v) {
  var s = v.toStringAsFixed(2);
  while (s.contains('.') && (s.endsWith('0') || s.endsWith('.'))) {
    s = s.substring(0, s.length - 1);
  }
  return '${s}x';
}
