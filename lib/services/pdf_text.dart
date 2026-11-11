import 'dart:math' as math;

import 'package:pdfrx/pdfrx.dart';

import '../models.dart';
import 'text_tools.dart';

/// Saca el texto de las páginas de un PDF (para leer en voz alta y para
/// el modo lectura). Usa su propia copia del documento.
class PdfTextSource {
  PdfTextSource(this.path);

  final String path;

  /// Contraseña, si el PDF la pide (la escribe el usuario en el visor).
  String? password;

  PdfDocument? _doc;
  Future<PdfDocument>? _opening;
  final Map<int, String> _cache = {};
  bool _disposed = false;

  Future<PdfDocument> _open() {
    final existing = _opening;
    if (existing != null) return existing;
    final future = _openNow();
    _opening = future;
    return future;
  }

  Future<PdfDocument> _openNow() async {
    var tried = false;
    try {
      final doc = await PdfDocument.openFile(
        path,
        passwordProvider: () {
          if (tried) return null;
          tried = true;
          return password;
        },
      );
      if (_disposed) {
        await doc.dispose();
        throw StateError('Documento cerrado');
      }
      _doc = doc;
      return doc;
    } catch (_) {
      _opening = null; // permite reintentar (por ejemplo, con contraseña)
      rethrow;
    }
  }

  Future<int> pageCount() async => (await _open()).pages.length;

  /// Texto de la página [index] (la primera es 0), ya acomodado en párrafos.
  Future<String> pageText(int index) async {
    final cached = _cache[index];
    if (cached != null) return cached;
    final doc = await _open();
    if (index < 0 || index >= doc.pages.length) return '';
    var raw = '';
    try {
      final t = await doc.pages[index].loadStructuredText();
      raw = t.fullText;
    } catch (_) {
      raw = '';
    }
    final text = reflowPdfPage(raw);
    _cache[index] = text;
    return text;
  }

  Future<List<PdfOutlineNode>> outline() async {
    try {
      return await (await _open()).loadOutline();
    } catch (_) {
      return const [];
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    final d = _doc;
    _doc = null;
    _cache.clear();
    if (d != null) await d.dispose();
  }
}

class ReflowCancelled implements Exception {
  const ReflowCancelled();
}

/// Resultado del "modo lectura" de un PDF.
class ReflowDoc {
  const ReflowDoc(this.doc, this.blockPages, this.pageCount);

  final ParsedDoc doc;

  /// Página (desde 1) de la que viene cada párrafo.
  final List<int> blockPages;
  final int pageCount;

  /// Primer párrafo de la página [page] (o de la siguiente que tenga texto).
  int blockForPage(int page) {
    final i = blockPages.indexWhere((p) => p >= page);
    if (i >= 0) return i;
    return blockPages.isEmpty ? 0 : blockPages.length - 1;
  }
}

/// Convierte todo el PDF en párrafos corridos que se adaptan a la pantalla.
Future<ReflowDoc> buildReflowDoc(
  PdfTextSource source, {
  void Function(int done, int total)? onProgress,
  bool Function()? isCancelled,
}) async {
  final total = await source.pageCount();
  final blocks = <TextBlock>[];
  final blockPages = <int>[];
  final pageStart = List<int>.filled(total, 0);

  for (var p = 0; p < total; p++) {
    if (isCancelled?.call() ?? false) throw const ReflowCancelled();
    final text = await source.pageText(p);
    pageStart[p] = blocks.length;
    final paragraphs =
        text.split('\n').where((s) => s.trim().isNotEmpty).toList();
    for (var k = 0; k < paragraphs.length; k++) {
      final para = paragraphs[k];
      // Un párrafo partido entre dos páginas se vuelve a unir.
      if (k == 0 &&
          blocks.isNotEmpty &&
          blockPages.last == p &&
          !endsSentence(blocks.last.text) &&
          isLowerLetter(para[0])) {
        final last = blocks.last.text;
        final joined = last.endsWith('-') && last.length > 1
            ? '${last.substring(0, last.length - 1)}$para'
            : '$last $para';
        blocks[blocks.length - 1] = TextBlock(joined);
        continue;
      }
      blocks.add(TextBlock(para));
      blockPages.add(p + 1);
    }
    onProgress?.call(p + 1, total);
  }

  final lastBlock = math.max(0, blocks.length - 1);
  final toc = <TocEntry>[];

  void walk(List<PdfOutlineNode> nodes, int level) {
    for (final n in nodes) {
      final page = n.dest?.pageNumber;
      if (page != null && page >= 1 && page <= total && n.title.trim().isNotEmpty) {
        toc.add(TocEntry(
          n.title.trim(),
          math.min(pageStart[page - 1], lastBlock),
          level: level.clamp(1, 3).toInt(),
        ));
      }
      walk(n.children, level + 1);
    }
  }

  walk(await source.outline(), 1);

  if (toc.isEmpty) {
    for (var p = 0; p < total; p++) {
      final next = p + 1 < total ? pageStart[p + 1] : blocks.length;
      if (next > pageStart[p]) toc.add(TocEntry('Página ${p + 1}', pageStart[p]));
    }
  }

  return ReflowDoc(ParsedDoc(blocks, toc), blockPages, total);
}
