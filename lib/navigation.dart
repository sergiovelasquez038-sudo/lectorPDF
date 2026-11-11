import 'dart:io';

import 'package:flutter/material.dart';

import 'models.dart';
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
  if (!File(doc.path).existsSync()) {
    LibraryStore.instance.removeDoc(doc.path);
    showMessage('Ese archivo ya no existe en el teléfono.');
    return;
  }
  final Widget screen = doc.type == DocType.pdf
      ? PdfReaderScreen(doc: doc)
      : TextReaderScreen(doc: doc);
  await navigatorKey.currentState
      ?.push(MaterialPageRoute<void>(builder: (_) => screen));
}
