import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../models.dart';

/// Abre un EPUB, Word o TXT en un hilo aparte y lo convierte en párrafos.
Future<ParsedDoc> loadTextDocument(String path, DocType type) =>
    Isolate.run(() => parseDocument(File(path).readAsBytesSync(), type));

ParsedDoc parseDocument(Uint8List bytes, DocType type) => switch (type) {
      DocType.epub => parseEpub(bytes),
      DocType.docx => parseDocx(bytes),
      DocType.txt => parseTxt(bytes),
      DocType.pdf => throw UnsupportedError('Los PDF usan el visor de PDF'),
      DocType.comic => throw UnsupportedError('Los manhua usan su propio lector'),
    };

// ===================== TXT y Markdown =====================

String decodeText(List<int> bytes) {
  // UTF-16 con marca de orden de bytes
  if (bytes.length >= 2 &&
      ((bytes[0] == 0xFF && bytes[1] == 0xFE) ||
          (bytes[0] == 0xFE && bytes[1] == 0xFF))) {
    final little = bytes[0] == 0xFF;
    final units = <int>[];
    for (var i = 2; i + 1 < bytes.length; i += 2) {
      units.add(little
          ? bytes[i] | (bytes[i + 1] << 8)
          : (bytes[i] << 8) | bytes[i + 1]);
    }
    return String.fromCharCodes(units);
  }
  var start = 0;
  if (bytes.length >= 3 &&
      bytes[0] == 0xEF &&
      bytes[1] == 0xBB &&
      bytes[2] == 0xBF) {
    start = 3;
  }
  final body = bytes.sublist(start);
  try {
    return utf8.decode(body);
  } on FormatException {
    // Archivos viejos de Windows (ANSI / Latin-1)
    return latin1.decode(body);
  }
}

final _mdHeading = RegExp(r'^(#{1,6})\s+(.+)$');

ParsedDoc parseTxt(List<int> bytes) {
  final text =
      decodeText(bytes).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final blocks = <TextBlock>[];
  final toc = <TocEntry>[];
  final buffer = StringBuffer();
  var prevLineLength = 0;

  void flush() {
    final t = buffer.toString().trim();
    buffer.clear();
    if (t.isNotEmpty) blocks.add(TextBlock(t));
  }

  for (final raw in text.split('\n')) {
    final line = raw.trimRight();
    final m = _mdHeading.firstMatch(line);
    if (m != null) {
      flush();
      final level = m.group(1)!.length.clamp(1, 3).toInt();
      final title = m.group(2)!.trim();
      toc.add(TocEntry(title, blocks.length, level: level));
      blocks.add(TextBlock(title, level: level));
    } else if (line.trim().isEmpty) {
      flush();
    } else {
      if (buffer.isNotEmpty) {
        // Líneas largas cortadas a mano (típico en libros .txt) se unen
        // para que el texto se acomode a la pantalla del teléfono.
        buffer.write(prevLineLength >= 55 ? ' ' : '\n');
      }
      buffer.write(buffer.isEmpty ? line.trimLeft() : line.trim());
      prevLineLength = line.length;
      if (buffer.length > 4000) flush();
    }
  }
  flush();
  return ParsedDoc(blocks, toc);
}

// ===================== Word (.docx) =====================

final _docxParagraph = RegExp(r'<w:p[ >].*?</w:p>', dotAll: true);
final _docxStyle = RegExp(r'<w:pStyle w:val="([^"]*)"');
final _docxRun =
    RegExp(r'<w:t(?:\s[^>]*)?>([^<]*)</w:t>|<w:tab/>|<w:br[^>]*/>|<w:cr/>');
final _docxHeadingStyle = RegExp(
    r'^(?:heading|ttulo|titulo|title|titre|berschrift|kop)\s*(\d?)',
    caseSensitive: false);

ParsedDoc parseDocx(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final file = archive.findFile('word/document.xml');
  if (file == null) {
    throw const FormatException('El archivo Word no tiene contenido legible');
  }
  final xml = utf8.decode(file.content, allowMalformed: true);

  final blocks = <TextBlock>[];
  final toc = <TocEntry>[];
  for (final pm in _docxParagraph.allMatches(xml)) {
    final para = pm.group(0)!;
    final text = StringBuffer();
    for (final r in _docxRun.allMatches(para)) {
      final t = r.group(1);
      if (t != null) {
        text.write(decodeEntities(t));
      } else if (r.group(0)!.startsWith('<w:tab')) {
        text.write('\t');
      } else {
        text.write('\n');
      }
    }
    var content = text.toString().trim();
    if (content.isEmpty) continue;

    var level = 0;
    final style = _docxStyle.firstMatch(para)?.group(1);
    if (style != null) {
      final h = _docxHeadingStyle.firstMatch(style);
      if (h != null) {
        final n = int.tryParse(h.group(1) ?? '') ?? 1;
        level = n.clamp(1, 3).toInt();
      }
    }
    if (level == 0 && para.contains('<w:numPr>')) content = '• $content';
    if (level > 0) toc.add(TocEntry(content, blocks.length, level: level));
    blocks.add(TextBlock(content, level: level));
  }
  if (blocks.isEmpty) {
    throw const FormatException('No se encontró texto en este documento');
  }
  return ParsedDoc(blocks, toc);
}

// ===================== EPUB =====================

final _attrRe = RegExp(r'''([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _fullPathRe = RegExp(r'''full-path\s*=\s*["']([^"']+)["']''');
final _manifestItemRe = RegExp(r'<(?:\w+:)?item\s[^>]*>');
final _spineItemRe = RegExp(r'<(?:\w+:)?itemref\s[^>]*>');

Map<String, String> _attrs(String tag) {
  final out = <String, String>{};
  for (final m in _attrRe.allMatches(tag)) {
    out[m.group(1)!] = m.group(2) ?? m.group(3) ?? '';
  }
  return out;
}

String _resolve(String baseDir, String href) {
  var h = href.split('#').first;
  try {
    h = Uri.decodeFull(h);
  } catch (_) {}
  final parts = <String>[];
  for (final seg in '$baseDir$h'.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
    } else {
      parts.add(seg);
    }
  }
  return parts.join('/');
}

ParsedDoc parseEpub(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final byName = <String, ArchiveFile>{};
  final byLower = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (!f.isFile) continue;
    byName[f.name] = f;
    byLower[f.name.toLowerCase()] = f;
  }
  ArchiveFile? find(String name) => byName[name] ?? byLower[name.toLowerCase()];
  String read(ArchiveFile f) => utf8.decode(f.content, allowMalformed: true);

  // 1. container.xml dice dónde está el archivo .opf
  var opfPath = '';
  final container = find('META-INF/container.xml');
  if (container != null) {
    opfPath = _fullPathRe.firstMatch(read(container))?.group(1) ?? '';
  }
  if (opfPath.isEmpty) {
    opfPath = byName.keys.firstWhere(
        (n) => n.toLowerCase().endsWith('.opf'),
        orElse: () => '');
  }

  // 2. El .opf trae la lista de capítulos en orden (spine)
  final chapters = <String>[];
  final opf = opfPath.isEmpty ? null : find(opfPath);
  if (opf != null) {
    final opfXml = read(opf);
    final slash = opfPath.lastIndexOf('/');
    final baseDir = slash >= 0 ? opfPath.substring(0, slash + 1) : '';
    final manifest = <String, String>{};
    for (final m in _manifestItemRe.allMatches(opfXml)) {
      final a = _attrs(m.group(0)!);
      final id = a['id'];
      final href = a['href'];
      if (id != null && href != null) manifest[id] = href;
    }
    for (final m in _spineItemRe.allMatches(opfXml)) {
      final href = manifest[_attrs(m.group(0)!)['idref']];
      if (href != null) chapters.add(_resolve(baseDir, href));
    }
  }
  if (chapters.isEmpty) {
    // EPUB dañado: leemos todos los HTML en orden alfabético
    chapters.addAll(byName.keys.where((n) {
      final l = n.toLowerCase();
      return l.endsWith('.xhtml') || l.endsWith('.html') || l.endsWith('.htm');
    }).toList()
      ..sort());
  }

  // 3. Cada capítulo se convierte en párrafos
  final blocks = <TextBlock>[];
  final toc = <TocEntry>[];
  final seen = <String>{};
  for (final name in chapters) {
    if (!seen.add(name)) continue;
    final f = find(name);
    if (f == null) continue;
    final chapterBlocks = htmlToBlocks(read(f));
    if (chapterBlocks.isEmpty) continue;

    final start = blocks.length;
    var addedHeading = false;
    for (var i = 0; i < chapterBlocks.length; i++) {
      final b = chapterBlocks[i];
      if (b.isHeading && b.level <= 2) {
        toc.add(TocEntry(b.text.replaceAll('\n', ' '), start + i,
            level: b.level));
        addedHeading = true;
      }
    }
    if (!addedHeading) {
      var title = chapterBlocks.first.text.replaceAll('\n', ' ');
      if (title.length > 60) title = '${title.substring(0, 57)}…';
      toc.add(TocEntry(title, start));
    }
    blocks.addAll(chapterBlocks);
  }
  if (blocks.isEmpty) {
    throw const FormatException('No se encontró texto en este libro');
  }
  return ParsedDoc(blocks, toc);
}

// ===================== Portada de EPUB =====================

final _metaRe = RegExp(r'<(?:\w+:)?meta\s[^>]*>');

/// Portada (imagen) de un EPUB, o null si no tiene.
Future<Uint8List?> loadEpubCover(String path) => Isolate.run(() {
      try {
        return extractEpubCover(File(path).readAsBytesSync());
      } catch (_) {
        return null;
      }
    });

Uint8List? extractEpubCover(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final byName = <String, ArchiveFile>{};
  final byLower = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (!f.isFile) continue;
    byName[f.name] = f;
    byLower[f.name.toLowerCase()] = f;
  }
  ArchiveFile? find(String name) => byName[name] ?? byLower[name.toLowerCase()];
  bool isImage(String name) {
    final l = name.toLowerCase();
    return l.endsWith('.jpg') ||
        l.endsWith('.jpeg') ||
        l.endsWith('.png') ||
        l.endsWith('.gif') ||
        l.endsWith('.webp');
  }

  var opfPath = '';
  final container = find('META-INF/container.xml');
  if (container != null) {
    opfPath = _fullPathRe
            .firstMatch(utf8.decode(container.content, allowMalformed: true))
            ?.group(1) ??
        '';
  }
  final opf = opfPath.isEmpty ? null : find(opfPath);
  if (opf != null) {
    final xml = utf8.decode(opf.content, allowMalformed: true);
    final slash = opfPath.lastIndexOf('/');
    final baseDir = slash >= 0 ? opfPath.substring(0, slash + 1) : '';

    String? coverId;
    for (final m in _metaRe.allMatches(xml)) {
      final a = _attrs(m.group(0)!);
      if (a['name'] == 'cover') coverId = a['content'];
    }
    final items = _manifestItemRe.allMatches(xml).map((m) => _attrs(m.group(0)!)).toList();
    String? href;
    for (final a in items) {
      if ((a['properties'] ?? '').contains('cover-image')) href = a['href'];
    }
    if (href == null && coverId != null) {
      for (final a in items) {
        if (a['id'] == coverId) href = a['href'];
      }
    }
    if (href == null) {
      for (final a in items) {
        final h = a['href'] ?? '';
        final id = a['id'] ?? '';
        final type = a['media-type'] ?? '';
        if (type.startsWith('image/') &&
            (id.toLowerCase().contains('cover') || h.toLowerCase().contains('cover'))) {
          href = h;
          break;
        }
      }
    }
    if (href != null && isImage(href)) {
      final f = find(_resolve(baseDir, href));
      if (f != null) return f.content;
    }
  }
  for (final f in archive.files) {
    if (f.isFile && isImage(f.name) && f.name.toLowerCase().contains('cover')) {
      return f.content;
    }
  }
  return null;
}

// ===================== HTML → párrafos =====================

const _blockTags = {
  'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'ul', 'ol',
  'blockquote', 'section', 'article', 'header', 'footer', 'aside', 'nav',
  'table', 'tr', 'td', 'th', 'pre', 'dd', 'dt', 'dl', 'figure',
  'figcaption', 'hr', 'body', 'main',
};

final _bodyRe = RegExp(r'<body[^>]*>', caseSensitive: false);
final _commentRe = RegExp(r'<!--.*?-->', dotAll: true);
final _skipRe = RegExp(r'<(script|style|head|title)\b[^>]*>.*?</\1\s*>',
    dotAll: true, caseSensitive: false);
final _tagRe = RegExp(r'<(/?)([a-zA-Z][\w:-]*)[^>]*>');
final _headingTagRe = RegExp(r'^h([1-6])$');
final _spaceRe = RegExp(r'\s+');

List<TextBlock> htmlToBlocks(String html) {
  var s = html;
  final body = _bodyRe.firstMatch(s);
  if (body != null) s = s.substring(body.end);
  s = s.replaceAll(_commentRe, ' ').replaceAll(_skipRe, ' ');

  final blocks = <TextBlock>[];
  final buf = StringBuffer();
  var level = 0;
  var prefix = '';

  void flush() {
    final lines = buf
        .toString()
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty);
    final text = lines.join('\n');
    buf.clear();
    if (text.isNotEmpty) {
      blocks.add(TextBlock('$prefix$text', level: level));
      prefix = '';
    }
  }

  void addText(String raw) {
    if (raw.isEmpty) return;
    buf.write(decodeEntities(raw).replaceAll(_spaceRe, ' '));
  }

  var pos = 0;
  for (final m in _tagRe.allMatches(s)) {
    if (m.start > pos) addText(s.substring(pos, m.start));
    pos = m.end;

    final closing = m.group(1) == '/';
    var tag = m.group(2)!.toLowerCase();
    final colon = tag.indexOf(':');
    if (colon >= 0) tag = tag.substring(colon + 1);

    if (tag == 'br') {
      buf.write('\n');
      continue;
    }
    if (!_blockTags.contains(tag)) continue;

    flush();
    final h = _headingTagRe.firstMatch(tag);
    if (h != null) {
      level = closing ? 0 : int.parse(h.group(1)!).clamp(1, 3).toInt();
    } else if (tag == 'li' && !closing) {
      prefix = '• ';
    }
  }
  if (pos < s.length) addText(s.substring(pos));
  flush();
  return blocks;
}

// ===================== Entidades (&amp; &#225; …) =====================

final _entityRe = RegExp(r'&(#[xX][0-9a-fA-F]+|#\d+|[a-zA-Z][a-zA-Z0-9]*);');

const _namedEntities = {
  'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'",
  'nbsp': ' ', 'shy': '', 'mdash': '—', 'ndash': '–', 'hellip': '…',
  'laquo': '«', 'raquo': '»', 'ldquo': '“', 'rdquo': '”', 'lsquo': '‘',
  'rsquo': '’', 'iexcl': '¡', 'iquest': '¿', 'aacute': 'á', 'eacute': 'é',
  'iacute': 'í', 'oacute': 'ó', 'uacute': 'ú', 'ntilde': 'ñ', 'uuml': 'ü',
  'Aacute': 'Á', 'Eacute': 'É', 'Iacute': 'Í', 'Oacute': 'Ó', 'Uacute': 'Ú',
  'Ntilde': 'Ñ', 'Uuml': 'Ü', 'ccedil': 'ç', 'Ccedil': 'Ç', 'agrave': 'à',
  'egrave': 'è', 'ograve': 'ò', 'copy': '©', 'reg': '®', 'deg': '°',
  'middot': '·', 'bull': '•', 'ordf': 'ª', 'ordm': 'º', 'euro': '€',
};

String decodeEntities(String s) {
  if (!s.contains('&')) return s;
  return s.replaceAllMapped(_entityRe, (m) {
    final e = m.group(1)!;
    if (e.startsWith('#')) {
      final hex = e.length > 1 && (e[1] == 'x' || e[1] == 'X');
      final code = hex
          ? int.tryParse(e.substring(2), radix: 16)
          : int.tryParse(e.substring(1));
      if (code == null || code <= 0 || code > 0x10FFFF) return m.group(0)!;
      return String.fromCharCode(code);
    }
    return _namedEntities[e] ?? m.group(0)!;
  });
}
