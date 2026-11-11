import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../navigation.dart';
import '../services/library_store.dart';
import '../services/read_aloud.dart';
import '../services/reader_settings.dart';
import '../services/tts_service.dart';
import '../widgets/voice_picker_sheet.dart';
import 'voices_screen.dart';

/// Configuración: voz de lectura, velocidad, apariencia y biblioteca.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  void _tryVoice() {
    final tts = TtsService.instance;
    ReadAloudController.current?.pause();
    final locale = tts.voiceLocale;
    final lang = locale == null ? deviceVoiceLanguage() : locale.split(RegExp('[-_]')).first;
    tts.stop().then((_) => tts.speakChunk(voiceSample(lang)));
  }

  @override
  Widget build(BuildContext context) {
    final tts = TtsService.instance;
    final settings = ReaderSettings.instance;
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: Listenable.merge([tts, settings]),
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Configuración')),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const SectionTitle('Voz de lectura'),
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  ListTile(
                    leading: CircleAvatar(
                      backgroundColor: scheme.primaryContainer,
                      child: Icon(Icons.record_voice_over_rounded,
                          color: scheme.onPrimaryContainer),
                    ),
                    title: const Text('Voz'),
                    subtitle: Text(currentVoiceLabel()),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => showVoicePicker(context),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.library_music_outlined),
                    title: const Text('Todas las voces, motores y descargas'),
                    subtitle: const Text('Google, Samsung, SherpaTTS y otros idiomas'),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(builder: (_) => const VoicesScreen())),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
              child: Text('Velocidad: ${formatSpeed(tts.speed)}'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Slider(
                value: tts.speed.clamp(0.5, 3.0).toDouble(),
                min: 0.5,
                max: 3.0,
                divisions: 25,
                label: formatSpeed(tts.speed),
                onChanged: tts.setSpeed,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
              child: Text('Tono: ${tts.pitch.toStringAsFixed(1)}'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Slider(
                value: tts.pitch.clamp(0.5, 2.0).toDouble(),
                min: 0.5,
                max: 2.0,
                divisions: 15,
                label: tts.pitch.toStringAsFixed(1),
                onChanged: tts.setPitch,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.tonalIcon(
                  icon: const Icon(Icons.play_arrow_rounded),
                  label: const Text('Probar la voz'),
                  onPressed: _tryVoice,
                ),
              ),
            ),
            const SectionTitle('Lectura'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
              child: Text('Tamaño de letra: ${settings.fontSize.round()}'),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Slider(
                value: settings.fontSize,
                min: 14,
                max: 32,
                divisions: 18,
                onChanged: settings.setFontSize,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: SizedBox(
                width: double.infinity,
                child: SegmentedButton<ReaderTheme>(
                  segments: [
                    for (final t in ReaderTheme.values)
                      ButtonSegment<ReaderTheme>(value: t, label: Text(t.label)),
                  ],
                  selected: {settings.theme},
                  onSelectionChanged: (s) => settings.setTheme(s.first),
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('Letra tipo libro'),
              value: settings.serif,
              onChanged: settings.setSerif,
            ),
            SwitchListTile(
              title: const Text('Mantener la pantalla encendida al leer'),
              subtitle: const Text('La lectura en voz alta sigue aunque la apagues.'),
              value: settings.keepScreenOn,
              onChanged: settings.setKeepScreenOn,
            ),
            const SectionTitle('PDF'),
            SwitchListTile(
              title: const Text('Modo noche'),
              value: settings.pdfNight,
              onChanged: settings.setPdfNight,
            ),
            SwitchListTile(
              title: const Text('Pasar páginas de lado'),
              value: settings.pdfHorizontal,
              onChanged: settings.setPdfHorizontal,
            ),
            const SectionTitle('Biblioteca'),
            ListTile(
              leading: const Icon(Icons.refresh_rounded),
              title: const Text('Buscar documentos otra vez'),
              onTap: () {
                LibraryStore.instance.scan();
                showMessage('Buscando documentos…');
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_rounded),
              title: const Text('Permiso de archivos'),
              subtitle: const Text('Abre los ajustes de Android de esta app'),
              onTap: openAppSettings,
            ),
            const SectionTitle('Acerca de'),
            const ListTile(
              leading: Icon(Icons.menu_book_rounded),
              title: Text('Lector 2.1'),
              subtitle: Text('PDF, EPUB, Word y TXT con lectura en voz alta'),
            ),
          ],
        ),
      ),
    );
  }
}
