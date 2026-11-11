import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'models.dart';
import 'navigation.dart';
import 'screens/library_screen.dart';
import 'services/annotations_store.dart';
import 'services/library_store.dart';
import 'services/read_aloud.dart';
import 'services/reader_settings.dart';
import 'services/system_bridge.dart';
import 'services/tts_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await pdfrxFlutterInitialize();
  } catch (e) {
    debugPrint('pdfrx: $e');
  }
  await ReaderSettings.instance.init();
  await AnnotationsStore.instance.init();
  await TtsService.instance.loadSettings();

  SystemBridge.init();
  SystemBridge.onFileOpened = _openIncomingFile;
  SystemBridge.onReadingToggle = () => ReadAloudController.current?.togglePlay(
      ReadAloudController.current?.item ?? 0);
  SystemBridge.onReadingStop = () => ReadAloudController.current?.stop();

  await LibraryStore.instance.init();
  runApp(const LectorApp());
  WidgetsBinding.instance.addPostFrameCallback((_) => _openIncomingFile());
}

/// Abre un documento que llegó desde otra app ("Abrir con…" o "Compartir").
Future<void> _openIncomingFile() async {
  final path = await SystemBridge.takeOpenedFile();
  if (path == null) return;
  if (docTypeForPath(path) == null) {
    showMessage('Ese tipo de archivo todavía no se puede abrir.');
    return;
  }
  final doc = LibraryStore.instance.addFile(path);
  if (doc == null) {
    showMessage('No se pudo abrir el archivo recibido.');
    return;
  }
  // Si ya hay un documento abierto, vuelve a la biblioteca antes de abrirlo.
  navigatorKey.currentState?.popUntil((route) => route.isFirst);
  await openDocument(doc);
}

class LectorApp extends StatelessWidget {
  const LectorApp({super.key});

  static const _seed = Color(0xFF1F6F78);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Lector',
      debugShowCheckedModeBanner: false,
      navigatorKey: navigatorKey,
      scaffoldMessengerKey: messengerKey,
      themeMode: ThemeMode.system,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: _seed),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
      ),
      home: const LibraryScreen(),
    );
  }
}
