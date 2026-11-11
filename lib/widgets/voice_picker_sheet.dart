import 'package:flutter/material.dart';

import '../screens/voices_screen.dart';
import '../services/tts_service.dart';

/// La primera vez que el usuario toca "Escuchar", le pide elegir una voz.
Future<void> askVoiceOnce(BuildContext context) async {
  final tts = TtsService.instance;
  if (tts.hasChosenVoice || tts.voicePrompted) return;
  await tts.markVoicePrompted();
  if (!context.mounted) return;
  await showVoicePicker(context);
}

/// Hoja para elegir rápido la voz que va a leer, con muestra de cada una.
Future<void> showVoicePicker(BuildContext context) => showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _VoicePickerSheet(),
    );

class _VoicePickerSheet extends StatefulWidget {
  const _VoicePickerSheet();

  @override
  State<_VoicePickerSheet> createState() => _VoicePickerSheetState();
}

class _VoicePickerSheetState extends State<_VoicePickerSheet> {
  final tts = TtsService.instance;
  late final String _language;
  List<TtsVoice> _voices = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _language = deviceVoiceLanguage();
    _load();
  }

  @override
  void dispose() {
    tts.stop();
    super.dispose();
  }

  Future<void> _load() async {
    final all = await tts.voices();
    if (!mounted) return;
    var list = all.where((v) => v.language == _language).toList();
    if (list.isEmpty) list = all;
    setState(() {
      _voices = sortVoices(list);
      _loading = false;
    });
  }

  Future<void> _choose(TtsVoice v) async {
    await tts.selectVoice(v);
    await tts.stop();
    tts.speakChunk(voiceSample(v.language));
  }

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: tts,
      builder: (context, _) {
        final numbers = voiceNumbers(_voices);
        return DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.95,
          builder: (context, sc) => Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
                child: Row(
                  children: [
                    Icon(Icons.record_voice_over_rounded, color: scheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text('Elige la voz que te va a leer',
                          style: t.titleLarge),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
                child: Text(
                  'Toca una voz para escucharla. Puedes cambiarla cuando '
                  'quieras en ⚙️ Configuración.',
                  style: t.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _voices.isEmpty
                        ? ListView(
                            controller: sc,
                            padding: const EdgeInsets.all(24),
                            children: const [
                              Text(
                                'Tu teléfono no tiene voces instaladas. Toca '
                                '"Más voces" para descargar las voces gratis de Google.',
                                textAlign: TextAlign.center,
                              ),
                            ],
                          )
                        : ListView.builder(
                            controller: sc,
                            itemCount: _voices.length,
                            itemBuilder: (context, i) {
                              final v = _voices[i];
                              final selected = tts.isSelected(v);
                              return ListTile(
                                leading: Icon(
                                  selected
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_unchecked,
                                  color: selected ? scheme.primary : scheme.outline,
                                ),
                                title: Text(voiceTitle(v, numbers)),
                                subtitle: Text(voiceTags(v)),
                                trailing: Icon(Icons.play_circle_outline_rounded,
                                    color: scheme.primary),
                                selected: selected,
                                onTap: () => _choose(v),
                              );
                            },
                          ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 16, 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        icon: const Icon(Icons.tune_rounded),
                        label: const Text('Más voces'),
                        onPressed: () {
                          Navigator.of(context).push(MaterialPageRoute<void>(
                              builder: (_) => const VoicesScreen()));
                        },
                      ),
                      const Spacer(),
                      FilledButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Listo'),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
