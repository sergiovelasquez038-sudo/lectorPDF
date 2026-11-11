import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum ReaderTheme {
  light('Claro'),
  sepia('Sepia'),
  dark('Noche');

  const ReaderTheme(this.label);
  final String label;
}

/// Preferencias de lectura: letra, interlineado, colores y modos.
class ReaderSettings extends ChangeNotifier {
  ReaderSettings._();
  static final ReaderSettings instance = ReaderSettings._();

  SharedPreferences? _prefs;

  double fontSize = 19;
  double lineHeight = 1.55;
  ReaderTheme theme = ReaderTheme.light;
  bool serif = true;
  bool pdfNight = false;
  bool pdfHorizontal = false;
  bool keepScreenOn = false;

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    fontSize = prefs.getDouble('fontSize') ?? 19;
    lineHeight = prefs.getDouble('lineHeight') ?? 1.55;
    final t = (prefs.getInt('theme') ?? 0).clamp(0, ReaderTheme.values.length - 1);
    theme = ReaderTheme.values[t.toInt()];
    serif = prefs.getBool('serif') ?? true;
    pdfNight = prefs.getBool('pdfNight') ?? false;
    pdfHorizontal = prefs.getBool('pdfHorizontal') ?? false;
    keepScreenOn = prefs.getBool('keepScreenOn') ?? false;
  }

  Color get background => switch (theme) {
        ReaderTheme.light => const Color(0xFFFFFFFF),
        ReaderTheme.sepia => const Color(0xFFF4ECD8),
        ReaderTheme.dark => const Color(0xFF121212),
      };

  Color get foreground => switch (theme) {
        ReaderTheme.light => const Color(0xFF1E1E1E),
        ReaderTheme.sepia => const Color(0xFF5B4636),
        ReaderTheme.dark => const Color(0xFFCFCFCF),
      };

  /// Fondo de la frase que se está leyendo en voz alta.
  Color get sentenceColor => switch (theme) {
        ReaderTheme.light => const Color(0xFFDCEEFF),
        ReaderTheme.sepia => const Color(0xFFE9DAB4),
        ReaderTheme.dark => const Color(0xFF233544),
      };

  /// Fondo de la palabra que se está leyendo en voz alta.
  Color get wordColor => switch (theme) {
        ReaderTheme.light => const Color(0xFF9FD0FF),
        ReaderTheme.sepia => const Color(0xFFD7B87A),
        ReaderTheme.dark => const Color(0xFF3F6E96),
      };

  bool get isDark => theme == ReaderTheme.dark;

  void setFontSize(double v) {
    fontSize = v;
    _prefs?.setDouble('fontSize', v);
    notifyListeners();
  }

  void setLineHeight(double v) {
    lineHeight = v;
    _prefs?.setDouble('lineHeight', v);
    notifyListeners();
  }

  void setTheme(ReaderTheme t) {
    theme = t;
    _prefs?.setInt('theme', t.index);
    notifyListeners();
  }

  void setSerif(bool v) {
    serif = v;
    _prefs?.setBool('serif', v);
    notifyListeners();
  }

  void setPdfNight(bool v) {
    pdfNight = v;
    _prefs?.setBool('pdfNight', v);
    notifyListeners();
  }

  void setPdfHorizontal(bool v) {
    pdfHorizontal = v;
    _prefs?.setBool('pdfHorizontal', v);
    notifyListeners();
  }

  void setKeepScreenOn(bool v) {
    keepScreenOn = v;
    _prefs?.setBool('keepScreenOn', v);
    notifyListeners();
  }
}
