import 'package:flutter/material.dart';

import 'models.dart';
import 'screens/comic_reader_screen.dart';
import 'screens/pdf_reader_screen.dart';
import 'screens/text_reader_screen.dart';
import 'services/library_store.dart';

final navigatorKey = GlobalKey<NavigatorState>();
final messengerKey = GlobalKey<ScaffoldMessengerState>();

/// Muestra un aviso corto en la parte de abajo de la pantalla.
void showMessage(String text, {SnackBarAction? action}) {
  final messenger = messengerKey.currentState;
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text), action: action));
}

/// Abre el lector adecuado según el formato.
Future<void> openDocument(DocItem doc) async {
  if (!doc.exists) {
    LibraryStore.instance.removeDoc(doc.path);
    showMessage('Ese archivo ya no existe en el teléfono.');
    return;
  }
  final Widget screen = switch (doc.type) {
    DocType.pdf => PdfReaderScreen(doc: doc),
    DocType.comic => ComicReaderScreen(doc: doc),
    _ => TextReaderScreen(doc: doc),
  };
  await navigatorKey.currentState
      ?.push(MaterialPageRoute<void>(builder: (_) => screen));
}
