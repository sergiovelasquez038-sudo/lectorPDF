import 'package:flutter/material.dart';

import '../services/read_aloud.dart';
import '../services/tts_service.dart';
import 'voice_picker_sheet.dart';

const _speeds = <double>[0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0];
const _sleepMinutes = <int>[10, 15, 30, 45, 60, 90];

/// Barra de controles mientras la app lee en voz alta.
class ReadAloudBar extends StatelessWidget {
  const ReadAloudBar({
    super.key,
    required this.controller,
    this.background,
    this.foreground,
  });

  final ReadAloudController controller;
  final Color? background;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final tts = TtsService.instance;
    return ListenableBuilder(
      listenable: Listenable.merge([controller, tts]),
      builder: (context, _) {
        final scheme = Theme.of(context).colorScheme;
        final fg = foreground ?? scheme.onSurface;
        final sleepAt = controller.sleepAt;
        final remaining = sleepAt?.difference(DateTime.now());
        return Material(
          color: background ?? scheme.surfaceContainer,
          elevation: 6,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (remaining != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        'Se detiene en ${remaining.inMinutes + 1} min',
                        style: TextStyle(color: fg.withValues(alpha: 0.7), fontSize: 12),
                      ),
                    ),
                  Row(
                    children: [
                      IconButton(
                        tooltip: 'Frase anterior',
                        color: fg,
                        icon: const Icon(Icons.skip_previous_rounded),
                        onPressed: () => controller.skip(-1),
                      ),
                      IconButton.filled(
                        tooltip: controller.isPlaying ? 'Pausar' : 'Seguir leyendo',
                        iconSize: 32,
                        icon: Icon(controller.isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                        onPressed: () => controller.togglePlay(controller.item),
                      ),
                      IconButton(
                        tooltip: 'Frase siguiente',
                        color: fg,
                        icon: const Icon(Icons.skip_next_rounded),
                        onPressed: () => controller.skip(1),
                      ),
                      const Spacer(),
                      PopupMenuButton<double>(
                        tooltip: 'Velocidad',
                        initialValue: tts.speed,
                        onSelected: tts.setSpeed,
                        itemBuilder: (_) => [
                          for (final s in _speeds)
                            PopupMenuItem(value: s, child: Text(formatSpeed(s))),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
                          child: Text(
                            formatSpeed(tts.speed),
                            style: TextStyle(color: fg, fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Cambiar voz',
                        color: fg,
                        icon: const Icon(Icons.record_voice_over_rounded),
                        onPressed: () {
                          controller.pause();
                          showVoicePicker(context);
                        },
                      ),
                      PopupMenuButton<int>(
                        tooltip: 'Temporizador para dormir',
                        icon: Icon(
                          sleepAt == null ? Icons.bedtime_outlined : Icons.bedtime_rounded,
                          color: fg,
                        ),
                        onSelected: (v) => controller
                            .setSleepTimer(v == 0 ? null : Duration(minutes: v)),
                        itemBuilder: (_) => [
                          for (final m in _sleepMinutes)
                            PopupMenuItem(value: m, child: Text('Detener en $m min')),
                          if (sleepAt != null)
                            const PopupMenuItem(value: 0, child: Text('Quitar temporizador')),
                        ],
                      ),
                      IconButton(
                        tooltip: 'Dejar de leer',
                        color: fg,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: controller.stop,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
