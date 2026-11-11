import 'package:flutter/material.dart';

import '../navigation.dart';
import '../services/read_aloud.dart';
import '../services/reader_settings.dart';
import '../services/system_bridge.dart';
import '../services/tts_service.dart';

const _languageNames = {
  'es': 'Español', 'en': 'Inglés', 'pt': 'Portugués', 'fr': 'Francés',
  'it': 'Italiano', 'de': 'Alemán', 'ca': 'Catalán', 'gl': 'Gallego',
  'eu': 'Euskera', 'nl': 'Neerlandés', 'pl': 'Polaco', 'ru': 'Ruso',
  'uk': 'Ucraniano', 'tr': 'Turco', 'ar': 'Árabe', 'hi': 'Hindi',
  'ja': 'Japonés', 'zh': 'Chino', 'yue': 'Cantonés', 'ko': 'Coreano',
  'sv': 'Sueco', 'da': 'Danés', 'nb': 'Noruego', 'fi': 'Finés',
  'el': 'Griego', 'he': 'Hebreo', 'id': 'Indonesio', 'vi': 'Vietnamita',
  'th': 'Tailandés', 'ro': 'Rumano', 'cs': 'Checo', 'hu': 'Húngaro',
  'qu': 'Quechua',
};

const _regionNames = {
  'ES': 'España', 'US': 'EE. UU.', 'MX': 'México', 'CO': 'Colombia',
  'AR': 'Argentina', 'CL': 'Chile', 'PE': 'Perú', 'VE': 'Venezuela',
  'EC': 'Ecuador', '419': 'Latinoamérica', 'GB': 'Reino Unido',
  'AU': 'Australia', 'IN': 'India', 'CA': 'Canadá', 'BR': 'Brasil',
  'PT': 'Portugal', 'FR': 'Francia', 'BE': 'Bélgica', 'DE': 'Alemania',
  'IT': 'Italia', 'NG': 'Nigeria', 'IE': 'Irlanda', 'ZA': 'Sudáfrica',
};

String localeLabel(String tag) {
  final parts = tag.split(RegExp('[-_]'));
  final lang = parts.first.toLowerCase();
  final name = _languageNames[lang] ?? lang.toUpperCase();
  if (parts.length < 2) return name;
  final region = parts[1].toUpperCase();
  return '$name (${_regionNames[region] ?? region})';
}

String voiceSample(String language) => switch (language) {
      'es' => 'Hola. Así sonará tu lectura con esta voz. ¿Te gusta cómo suena?',
      'pt' => 'Olá! É assim que a sua leitura vai soar com esta voz.',
      'fr' => 'Bonjour ! Voici comment votre lecture sonnera avec cette voix.',
      'it' => 'Ciao! Ecco come suonerà la tua lettura con questa voce.',
      'de' => 'Hallo! So klingt dein Buch mit dieser Stimme.',
      _ => 'Hello! This is how your reading will sound with this voice.',
    };

/// Idioma del teléfono, si tenemos su nombre; si no, español.
String deviceVoiceLanguage() {
  final device = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
  return _languageNames.containsKey(device) ? device : 'es';
}

String languageName(String code) => _languageNames[code] ?? code;

/// Numera las voces de cada país: "Voz 1", "Voz 2"… (la versión con y sin
/// internet de una misma voz comparten número).
Map<String, int> voiceNumbers(Iterable<TtsVoice> voices) {
  final numbers = <String, int>{};
  final perLocale = <String, int>{};
  for (final v in voices) {
    final key = '${v.locale}|${v.variant}';
    if (!numbers.containsKey(key)) {
      final n = (perLocale[v.locale] ?? 0) + 1;
      perLocale[v.locale] = n;
      numbers[key] = n;
    }
  }
  return numbers;
}

String voiceTitle(TtsVoice v, Map<String, int> numbers) {
  final n = numbers['${v.locale}|${v.variant}'] ?? 1;
  final code = v.variant.isEmpty ? '' : ' (${v.variant})';
  return '${localeLabel(v.locale)} · Voz $n$code';
}

String voiceTags(TtsVoice v) => [
      v.network ? 'Con internet · más natural' : 'Sin internet',
      if (v.highQuality) 'Alta calidad',
      if (!v.installed) 'Falta descargar',
    ].join(' · ');

/// Ordena: primero el país del teléfono, luego las instaladas y las mejores.
List<TtsVoice> sortVoices(Iterable<TtsVoice> voices) {
  final list = voices.toList();
  list.sort((a, b) {
    final l = a.locale.compareTo(b.locale);
    if (l != 0) return l;
    if (a.installed != b.installed) return a.installed ? -1 : 1;
    final v = a.variant.compareTo(b.variant);
    if (v != 0) return v;
    if (a.network != b.network) return a.network ? 1 : -1;
    return a.name.compareTo(b.name);
  });
  return list;
}

/// Nombre de la voz elegida, para mostrar en Configuración.
String currentVoiceLabel() {
  final tts = TtsService.instance;
  final name = tts.voiceName;
  final locale = tts.voiceLocale;
  if (name == null || locale == null) return 'La del teléfono (sin elegir)';
  final v = TtsVoice(name: name, locale: locale);
  return v.variant.isEmpty
      ? localeLabel(locale)
      : '${localeLabel(locale)} · ${v.variant}';
}

/// Pantalla para elegir motor de voz, voz, velocidad y tono.
class VoicesScreen extends StatefulWidget {
  const VoicesScreen({super.key});

  @override
  State<VoicesScreen> createState() => _VoicesScreenState();
}

class _VoicesScreenState extends State<VoicesScreen> {
  final tts = TtsService.instance;
  late final AppLifecycleListener _lifecycle;

  bool _loading = true;
  List<String> _engines = const [];
  String? _defaultEngine;
  List<TtsVoice> _voices = const [];
  bool _allLanguages = false;
  late String _language;

  @override
  void initState() {
    super.initState();
    _language = deviceVoiceLanguage();
    // Si estaba leyendo, pausa para poder probar voces.
    WidgetsBinding.instance
        .addPostFrameCallback((_) => ReadAloudController.current?.pause());
    // Al volver de instalar voces o un motor nuevo, recarga la lista.
    _lifecycle = AppLifecycleListener(onResume: _load);
    _load();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    tts.stop();
    super.dispose();
  }

  Future<void> _load() async {
    if (mounted && !_loading) setState(() => _loading = true);
    final engines = await tts.engines();
    final def = await tts.defaultEngine();
    final voices = await tts.voices();
    if (!mounted) return;
    setState(() {
      _engines = engines;
      _defaultEngine = def;
      _voices = voices;
      _loading = false;
    });
  }

  String? get _currentEngine => tts.engine ?? _defaultEngine;

  Future<void> _selectEngine(String engine) async {
    if (engine == _currentEngine) return;
    setState(() => _loading = true);
    final ok = await tts.selectEngine(engine);
    if (!ok) showMessage('No se pudo usar ${engineLabel(engine)}.');
    await _load();
  }

  Future<void> _preview(TtsVoice? voice) async {
    if (voice != null && !tts.isSelected(voice)) await tts.selectVoice(voice);
    final lang = voice?.language ?? _language;
    await tts.stop();
    tts.speakChunk(voiceSample(lang));
  }

  List<TtsVoice> _visibleVoices() => sortVoices(
      _voices.where((v) => _allLanguages || v.language == _language));

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([tts, ReaderSettings.instance]),
      builder: (context, _) {
        final textTheme = Theme.of(context).textTheme;
        final visible = _visibleVoices();
        final langCount = _voices.where((v) => v.language == _language).length;

        final numbers = voiceNumbers(visible);

        return Scaffold(
          appBar: AppBar(
            title: const Text('Elegir voz'),
            actions: [
              IconButton(
                tooltip: 'Actualizar',
                icon: const Icon(Icons.refresh_rounded),
                onPressed: _loading ? null : _load,
              ),
            ],
            bottom: _loading
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(3),
                    child: LinearProgressIndicator(minHeight: 3),
                  )
                : null,
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              SectionTitle('Velocidad y tono'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Velocidad: ${formatSpeed(tts.speed)}'),
                    Slider(
                      value: tts.speed.clamp(0.5, 3.0).toDouble(),
                      min: 0.5,
                      max: 3.0,
                      divisions: 25,
                      label: formatSpeed(tts.speed),
                      onChanged: tts.setSpeed,
                    ),
                    Text('Tono: ${tts.pitch.toStringAsFixed(1)}'),
                    Slider(
                      value: tts.pitch.clamp(0.5, 2.0).toDouble(),
                      min: 0.5,
                      max: 2.0,
                      divisions: 15,
                      label: tts.pitch.toStringAsFixed(1),
                      onChanged: tts.setPitch,
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.play_arrow_rounded),
                        label: const Text('Escuchar ejemplo'),
                        onPressed: () => _preview(null),
                      ),
                    ),
                  ],
                ),
              ),
              if (_engines.length > 1) ...[
                SectionTitle('Motor de voz'),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: [
                      for (final e in _engines)
                        ChoiceChip(
                          label: Text(engineLabel(e)),
                          selected: e == _currentEngine,
                          onSelected: _loading ? null : (_) => _selectEngine(e),
                        ),
                    ],
                  ),
                ),
              ],
              SectionTitle('Voces'),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    ChoiceChip(
                      label: Text('${_languageNames[_language] ?? _language} · $langCount'),
                      selected: !_allLanguages,
                      onSelected: (_) => setState(() => _allLanguages = false),
                    ),
                    ChoiceChip(
                      label: Text('Todos los idiomas · ${_voices.length}'),
                      selected: _allLanguages,
                      onSelected: (_) => setState(() => _allLanguages = true),
                    ),
                  ],
                ),
              ),
              if (!_loading && visible.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _voices.isEmpty
                        ? 'No encontramos voces. Instala las voces de Google (abajo) y vuelve a esta pantalla.'
                        : 'Este motor no tiene voces en ${_languageNames[_language] ?? _language}. Prueba otro motor o descarga voces abajo.',
                    style: textTheme.bodyMedium,
                  ),
                ),
              for (final v in visible) _voiceTile(v, numbers),
              SectionTitle('Conseguir más voces gratis'),
              if (_engines.contains(kGoogleTts))
                ListTile(
                  leading: const Icon(Icons.download_rounded),
                  title: const Text('Descargar voces de Google'),
                  subtitle: const Text(
                      'Elige "Español" y descarga las voces para usarlas sin internet.'),
                  onTap: () async {
                    final ok = await SystemBridge.installTtsData(kGoogleTts);
                    if (!ok) await SystemBridge.openTtsSettings();
                  },
                )
              else
                ListTile(
                  leading: const Icon(Icons.shop_rounded),
                  title: const Text('Instalar las voces de Google'),
                  subtitle: const Text('Gratis en Play Store ("Servicios de voz de Google").'),
                  onTap: () => SystemBridge.openStore(kGoogleTts),
                ),
              ListTile(
                leading: const Icon(Icons.auto_awesome_rounded),
                title: const Text('Voces neuronales sin internet (SherpaTTS)'),
                subtitle: const Text(
                    'App gratuita y de código abierto con voces Piper muy naturales. '
                    'Instálala, ábrela, descarga una voz en español y vuelve aquí: '
                    'aparecerá como motor.'),
                isThreeLine: true,
                onTap: () async {
                  final ok = await SystemBridge.openUrl(
                      'https://f-droid.org/packages/$kSherpaTts/');
                  if (!ok) showMessage('No se pudo abrir el navegador.');
                },
              ),
              ListTile(
                leading: const Icon(Icons.settings_voice_rounded),
                title: const Text('Ajustes de voz de Android'),
                subtitle: const Text('Motor predeterminado y descarga de idiomas.'),
                onTap: () async {
                  final ok = await SystemBridge.openTtsSettings();
                  if (!ok) showMessage('Tu teléfono no permite abrir esos ajustes desde aquí.');
                },
              ),
              const Divider(height: 32),
              SwitchListTile(
                secondary: const Icon(Icons.light_mode_outlined),
                title: const Text('Mantener la pantalla encendida al leer'),
                subtitle: const Text(
                    'La lectura en voz alta sigue aunque apagues la pantalla.'),
                value: ReaderSettings.instance.keepScreenOn,
                onChanged: ReaderSettings.instance.setKeepScreenOn,
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text(
                  'Consejo: las voces marcadas "con internet" de Google suenan más '
                  'naturales; las demás funcionan sin conexión. Si la lectura se '
                  'corta con la pantalla apagada, en Ajustes > Apps > Lector > '
                  'Batería elige "Sin restricciones".',
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _voiceTile(TtsVoice v, Map<String, int> numbers) {
    final selected = tts.isSelected(v);
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? scheme.primary : scheme.outline,
      ),
      title: Text(voiceTitle(v, numbers)),
      subtitle: Text(voiceTags(v)),
      trailing: IconButton(
        tooltip: 'Escuchar',
        icon: const Icon(Icons.play_circle_outline_rounded),
        onPressed: () => _preview(v),
      ),
      selected: selected,
      onTap: () => _preview(v),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}
