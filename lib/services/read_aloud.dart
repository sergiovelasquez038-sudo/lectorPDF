import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

import 'system_bridge.dart';
import 'text_tools.dart';
import 'tts_service.dart';

enum ReadState { stopped, playing, paused }

/// Devuelve el texto de un elemento (párrafo o página) para leerlo.
typedef ItemTextLoader = Future<String> Function(int index);

/// Lee un documento en voz alta, frase por frase, y avisa qué frase
/// y qué palabra se están leyendo para poder resaltarlas.
class ReadAloudController extends ChangeNotifier {
  ReadAloudController({
    required this.title,
    required this.itemCount,
    required this.loadItem,
    this.onItemStart,
    this.onMessage,
  });

  /// La lectura que está sonando ahora (solo puede haber una).
  static ReadAloudController? current;
  static bool _askedNotifications = false;

  final String title;
  int itemCount;
  final ItemTextLoader loadItem;

  /// Se llama al empezar a leer un elemento (para pasar de página o
  /// desplazar el texto).
  void Function(int index)? onItemStart;
  void Function(String message)? onMessage;

  ReadState state = ReadState.stopped;
  int item = 0;
  int? wordStart;
  int? wordEnd;
  DateTime? sleepAt;

  List<TextSegment> _segments = const [];
  int _segIndex = 0;
  int _run = 0;
  bool _disposed = false;
  Timer? _sleepTimer;

  bool get isActive => state != ReadState.stopped;
  bool get isPlaying => state == ReadState.playing;

  /// Frase actual dentro del elemento [item].
  TextSegment? get sentence =>
      _segIndex >= 0 && _segIndex < _segments.length ? _segments[_segIndex] : null;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  /// Empieza a leer desde el elemento [index], en la posición [offset].
  Future<void> playFrom(int index, {int offset = 0}) async {
    if (itemCount <= 0) return;
    final run = ++_run;
    final other = current;
    if (other != null && !identical(other, this)) await other.stop();
    current = this;
    await TtsService.instance.stop();
    if (run != _run) return;

    state = ReadState.playing;
    item = index.clamp(0, itemCount - 1).toInt();
    _notify();

    if (!_askedNotifications) {
      _askedNotifications = true;
      try {
        // Android 13+: permiso para mostrar los controles en la notificación
        await Permission.notification.request();
      } catch (_) {}
      if (run != _run) return;
    }
    // Si el servicio ya está activo, solo actualiza la notificación.
    unawaited(SystemBridge.startReading(title));
    await _loop(run, item, offset);
  }

  Future<void> _loop(int run, int startItem, int startOffset) async {
    var i = startItem;
    var offset = startOffset;
    var errors = 0;
    var spoke = false;

    while (run == _run && i < itemCount) {
      String text;
      try {
        text = await loadItem(i);
      } catch (_) {
        text = '';
      }
      if (run != _run) return;

      item = i;
      _segments = splitSentences(text);
      _segIndex = 0;
      if (offset > 0) {
        final k = _segments.indexWhere((s) => s.end > offset);
        _segIndex = k < 0 ? _segments.length : k;
      }
      wordStart = null;
      wordEnd = null;
      if (_segIndex < _segments.length) onItemStart?.call(i);
      _notify();

      while (run == _run && _segIndex < _segments.length) {
        final seg = _segments[_segIndex];
        wordStart = null;
        wordEnd = null;
        _notify();
        final spoken = speakableText(text.substring(seg.start, seg.end));
        final ok = await TtsService.instance.speakChunk(spoken, onWord: (s, e) {
          if (run != _run) return;
          wordStart = seg.start + s;
          wordEnd = seg.start + e;
          _notify();
        });
        if (run != _run) return;
        if (ok) {
          errors = 0;
          spoke = true;
        } else if (++errors >= 3) {
          await stop();
          onMessage?.call(
              'La voz no responde. Prueba otra voz en "Voces de lectura".');
          return;
        }
        _segIndex++;
      }
      i++;
      offset = 0;
    }

    if (run == _run) {
      await stop();
      onMessage?.call(spoke
          ? 'Fin de la lectura.'
          : 'No hay texto para leer aquí. Si es un PDF escaneado (fotos de páginas), no contiene texto.');
    }
  }

  Future<void> pause() async {
    if (state != ReadState.playing) return;
    _run++;
    state = ReadState.paused;
    wordStart = null;
    wordEnd = null;
    await TtsService.instance.stop();
    unawaited(SystemBridge.updateReading(title, false));
    _notify();
  }

  Future<void> resume() async {
    if (state != ReadState.paused) return;
    await playFrom(item, offset: sentence?.start ?? 0);
  }

  Future<void> togglePlay([int fallbackIndex = 0]) async {
    switch (state) {
      case ReadState.playing:
        await pause();
      case ReadState.paused:
        await resume();
      case ReadState.stopped:
        await playFrom(fallbackIndex);
    }
  }

  Future<void> stop() async {
    _run++;
    final wasActive = isActive;
    state = ReadState.stopped;
    wordStart = null;
    wordEnd = null;
    _cancelSleep();
    await TtsService.instance.stop();
    if (wasActive) unawaited(SystemBridge.stopReading());
    if (identical(current, this)) current = null;
    _notify();
  }

  /// Salta [delta] frases hacia adelante (1) o hacia atrás (-1).
  Future<void> skip(int delta) async {
    if (state == ReadState.stopped) return;
    final target = _segIndex + delta;
    if (target >= _segments.length) {
      if (item + 1 < itemCount) await playFrom(item + 1);
      return;
    }
    if (target < 0) {
      if (item > 0) {
        await playFrom(item - 1);
      } else {
        await playFrom(0);
      }
      return;
    }
    if (state == ReadState.paused) {
      _segIndex = target;
      _notify();
      return;
    }
    await playFrom(item, offset: _segments[target].start);
  }

  // ---------- Temporizador para dormir ----------

  void setSleepTimer(Duration? duration) {
    _cancelSleep();
    if (duration != null) {
      sleepAt = DateTime.now().add(duration);
      _sleepTimer = Timer(duration, () {
        sleepAt = null;
        pause();
        onMessage?.call('Temporizador: lectura en pausa.');
      });
    }
    _notify();
  }

  void _cancelSleep() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    sleepAt = null;
  }

  @override
  void dispose() {
    if (isActive) {
      _run++;
      _cancelSleep();
      TtsService.instance.stop();
      SystemBridge.stopReading();
      if (identical(current, this)) current = null;
    }
    _disposed = true;
    super.dispose();
  }
}
