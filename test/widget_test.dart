import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lector_docs/models.dart';
import 'package:lector_docs/services/extractors.dart';
import 'package:lector_docs/services/text_tools.dart';
import 'package:lector_docs/services/tts_service.dart';

void main() {
  test('decodifica entidades HTML', () {
    expect(decodeEntities('Caf&#233; &amp; t&eacute; &#x2014; fin'),
        'Café & té — fin');
  });

  test('convierte HTML en párrafos y títulos', () {
    final blocks = htmlToBlocks(
        '<html><head><title>x</title></head><body><h1>Capítulo 1</h1>'
        '<p>Hola\n   mundo</p><ul><li>uno</li></ul></body></html>');
    expect(blocks.map((b) => b.text).toList(),
        ['Capítulo 1', 'Hola mundo', '• uno']);
    expect(blocks.first.level, 1);
  });

  test('lee TXT y Markdown', () {
    final doc = parseTxt(utf8.encode('# Título\n\nPrimer párrafo.\n\nSegundo.'));
    expect(doc.blocks.length, 3);
    expect(doc.toc.single.title, 'Título');
  });

  test('busca sin tildes', () {
    expect(foldText('Canción ÁRBOL'), 'cancion arbol');
  });

  test('divide frases para leer en voz alta', () {
    const text = 'El Sr. Pérez llegó. ¿Vienes? ¡Claro! Fin';
    final parts =
        splitSentences(text).map((s) => text.substring(s.start, s.end)).toList();
    expect(parts, ['El Sr. Pérez llegó.', '¿Vienes?', '¡Claro!', 'Fin']);
  });

  test('frases muy largas se cortan', () {
    final text = List.filled(120, 'palabra').join(' ');
    final parts = splitSentences(text, maxLength: 100);
    expect(parts.length, greaterThan(1));
    for (final s in parts) {
      expect(s.length, lessThanOrEqualTo(100));
    }
  });

  test('símbolos se cambian por espacios sin mover posiciones', () {
    expect(speakableText('• Hola *mundo*'), '  Hola  mundo ');
  });

  test('une renglones de PDF en párrafos', () {
    const raw = 'Este es un renglón bastante largo que continúa en la línea\n'
        'siguiente y termina más adelante con una palabra que fue cor-\n'
        'tada justo al final del renglón.\n'
        'Nuevo párrafo que empieza aquí y también es bastante largo.\n'
        '12';
    expect(
        reflowPdfPage(raw),
        'Este es un renglón bastante largo que continúa en la línea siguiente '
        'y termina más adelante con una palabra que fue cortada justo al final '
        'del renglón.\n'
        'Nuevo párrafo que empieza aquí y también es bastante largo.');
  });

  test('velocidad legible', () {
    expect(formatSpeed(1.0), '1x');
    expect(formatSpeed(1.25), '1.25x');
    expect(formatSpeed(0.8), '0.8x');
  });
}
