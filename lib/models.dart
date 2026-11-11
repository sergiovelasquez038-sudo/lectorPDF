import 'dart:io';

import 'package:path/path.dart' as p;

/// Formatos que la app sabe abrir.
enum DocType {
  pdf('PDF', 0xFFD9443A),
  epub('EPUB', 0xFF2E8B57),
  docx('Word', 0xFF2B5DB8),
  txt('Texto', 0xFF8A6D3B);

  const DocType(this.label, this.colorValue);
  final String label;
  final int colorValue;
}

const Map<String, DocType> kExtensions = {
  '.pdf': DocType.pdf,
  '.epub': DocType.epub,
  '.docx': DocType.docx,
  '.txt': DocType.txt,
  '.md': DocType.txt,
};

DocType? docTypeForPath(String path) =>
    kExtensions[p.extension(path).toLowerCase()];

/// Un documento encontrado en el teléfono.
class DocItem {
  const DocItem({
    required this.path,
    required this.size,
    required this.modifiedMs,
  });

  final String path;
  final int size;
  final int modifiedMs;

  DocType get type => docTypeForPath(path) ?? DocType.txt;
  String get name => p.basenameWithoutExtension(path);
  String get folder => p.basename(p.dirname(path));
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(modifiedMs);

  Map<String, dynamic> toJson() => {'p': path, 's': size, 'm': modifiedMs};

  static DocItem fromJson(Map<String, dynamic> j) => DocItem(
        path: j['p'] as String,
        size: (j['s'] as num).toInt(),
        modifiedMs: (j['m'] as num).toInt(),
      );

  /// Lee tamaño y fecha de un archivo. null si no existe.
  static DocItem? fromFile(String path) {
    try {
      final st = File(path).statSync();
      if (st.type != FileSystemEntityType.file) return null;
      return DocItem(
        path: path,
        size: st.size,
        modifiedMs: st.modified.millisecondsSinceEpoch,
      );
    } catch (_) {
      return null;
    }
  }
}

/// Dónde quedó el lector en un documento.
/// En PDF [position] es el número de página; en los demás, el párrafo.
class ReadingProgress {
  const ReadingProgress({
    required this.position,
    required this.fraction,
    required this.openedMs,
  });

  final int position;
  final double fraction;
  final int openedMs;

  Map<String, dynamic> toJson() =>
      {'pos': position, 'f': fraction, 'at': openedMs};

  static ReadingProgress fromJson(Map<String, dynamic> j) => ReadingProgress(
        position: (j['pos'] as num).toInt(),
        fraction: (j['f'] as num).toDouble(),
        openedMs: (j['at'] as num).toInt(),
      );
}

/// Un párrafo o título de un documento de texto (EPUB, Word, TXT).
class TextBlock {
  const TextBlock(this.text, {this.level = 0});

  final String text;

  /// 0 = párrafo normal, 1 a 3 = título.
  final int level;

  bool get isHeading => level > 0;
}

/// Una entrada del índice.
class TocEntry {
  const TocEntry(this.title, this.index, {this.level = 1});

  final String title;
  final int index;
  final int level;
}

class ParsedDoc {
  const ParsedDoc(this.blocks, this.toc);

  final List<TextBlock> blocks;
  final List<TocEntry> toc;
}

String formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
}

String formatDate(DateTime d) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(d.day)}/${two(d.month)}/${d.year}';
}

const _foldFrom = 'áàäâéèëêíìïîóòöôúùüûñçÁÀÄÂÉÈËÊÍÌÏÎÓÒÖÔÚÙÜÛÑÇ';
const _foldTo = 'aaaaeeeeiiiioooouuuuncAAAAEEEEIIIIOOOOUUUUNC';
final Map<int, int> _foldMap = {
  for (var i = 0; i < _foldFrom.length; i++)
    _foldFrom.codeUnitAt(i): _foldTo.codeUnitAt(i),
};

/// Quita tildes y mayúsculas para que buscar "cancion" encuentre "Canción".
/// Conserva la longitud del texto (salvo letras muy raras).
String foldText(String s) {
  final units = s.codeUnits;
  final out = List<int>.filled(units.length, 0);
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    out[i] = _foldMap[c] ?? c;
  }
  return String.fromCharCodes(out).toLowerCase();
}
