import 'dart:async';

import 'package:flutter/material.dart';

/// Guarda los últimos errores de la app para poder verlos y copiarlos en
/// Configuración, y muestra un aviso legible en vez de una pantalla rota.
class ErrorLog {
  ErrorLog._();

  static final ValueNotifier<List<String>> entries = ValueNotifier(const []);

  static void add(Object error, [StackTrace? stack]) {
    final where = (stack?.toString() ?? '')
        .split('\n')
        .where((l) => l.contains('package:'))
        .take(6)
        .join('\n');
    final time = DateTime.now().toIso8601String().substring(11, 19);
    final text = '$time  $error${where.isEmpty ? '' : '\n$where'}';
    // Se avisa después del cuadro actual, nunca en medio de un dibujo.
    scheduleMicrotask(() {
      entries.value = [text, ...entries.value].take(20).toList();
    });
  }

  static void install() {
    final previous = FlutterError.onError;
    FlutterError.onError = (details) {
      add(details.exception, details.stack);
      previous?.call(details);
    };
    WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
      add(error, stack);
      return true;
    };
    ErrorWidget.builder = (details) => Directionality(
          textDirection: TextDirection.ltr,
          child: ColoredBox(
            color: const Color(0xFFFFF3E0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                'Algo falló al mostrar esta parte:\n${details.exceptionAsString()}',
                style: const TextStyle(color: Color(0xFF5D4037), fontSize: 13),
              ),
            ),
          ),
        );
  }
}
