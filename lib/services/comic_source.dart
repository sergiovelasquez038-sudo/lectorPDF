import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import '../models.dart';

/// Páginas (rutas de imágenes) de un manhua o cómic, en orden de lectura.
/// - Carpeta de capítulo: sus imágenes ordenadas.
/// - CBZ o EPUB de imágenes: se extraen una vez a la caché de la app.
Future<List<String>> loadComicPages(DocItem doc) async {
  final path = doc.path;
  if (doc.isFolder) return Isolate.run(() => _folderPages(path));
  final cache = _cacheDirFor(doc);
  final isEpub = p.extension(path).toLowerCase() == '.epub';
  final pages = await Isolate.run(() => _extractPages(path, cache, isEpub));
  _cleanOldCaches(cache);
  return pages;
}

/// Primera página (portada) como bytes, para la biblioteca.
Future<Uint8List?> loadComicCover(DocItem doc) {
  final path = doc.path;
  final folder = doc.isFolder;
  return Isolate.run(() {
    try {
      if (folder) {
        final pages = _folderPages(path);
        return pages.isEmpty ? null : File(pages.first).readAsBytesSync();
      }
      final input = InputFileStream(path);
      try {
        final archive = ZipDecoder().decodeStream(input);
        final images = _zipImages(archive);
        return images.isEmpty ? null : images.first.content;
      } finally {
        input.closeSync();
      }
    } catch (_) {
      return null;
    }
  });
}

// ---------------------------------------------------------------------------

List<String> _folderPages(String dirPath) {
  final files = <String>[];
  for (final e in Directory(dirPath).listSync(followLinks: false)) {
    if (e is File && isImagePath(e.path) && !p.basename(e.path).startsWith('.')) {
      files.add(e.path);
    }
  }
  files.sort((a, b) => naturalCompare(p.basename(a), p.basename(b)));
  return files;
}

bool _isJunk(String name) {
  final l = name.toLowerCase();
  return l.startsWith('__macosx/') || p.basename(l).startsWith('.');
}

List<ArchiveFile> _zipImages(Archive archive) {
  final list = archive.files
      .where((f) => f.isFile && isImagePath(f.name) && !_isJunk(f.name))
      .toList();
  list.sort((a, b) => naturalCompare(a.name, b.name));
  return list;
}

String _cacheDirFor(DocItem doc) {
  // Huella simple (FNV-1a de 32 bits) de la ruta, tamaño y fecha del archivo.
  var h = 0x811c9dc5;
  for (final c in utf8.encode('${doc.path}|${doc.size}|${doc.modifiedMs}')) {
    h = ((h ^ c) * 0x01000193) & 0xffffffff;
  }
  return '${Directory.systemTemp.path}/manhua/${h.toRadixString(16)}';
}

List<String> _extractPages(String zipPath, String cacheDir, bool isEpub) {
  final listFile = File('$cacheDir/.paginas');
  if (listFile.existsSync()) {
    final saved = listFile.readAsLinesSync().where((l) => l.isNotEmpty).toList();
    if (saved.isNotEmpty && saved.every((f) => File(f).existsSync())) {
      listFile.setLastModifiedSync(DateTime.now());
      return saved;
    }
  }
  Directory(cacheDir).createSync(recursive: true);
  final input = InputFileStream(zipPath);
  try {
    final archive = ZipDecoder().decodeStream(input);
    final files = isEpub ? _epubImages(archive) : _zipImages(archive);
    final out = <String>[];
    for (var i = 0; i < files.length; i++) {
      final f = files[i];
      final target =
          '$cacheDir/${i.toString().padLeft(5, '0')}${p.extension(f.name).toLowerCase()}';
      File(target).writeAsBytesSync(f.content);
      out.add(target);
    }
    listFile.writeAsStringSync(out.join('\n'));
    return out;
  } finally {
    input.closeSync();
  }
}

/// Borra las cachés más viejas: se guardan los últimos 8 capítulos.
void _cleanOldCaches(String keep) {
  try {
    final root = Directory(p.dirname(keep));
    DateTime used(Directory d) {
      final f = File('${d.path}/.paginas');
      return f.existsSync() ? f.lastModifiedSync() : d.statSync().modified;
    }

    final dirs = root.listSync().whereType<Directory>().toList()
      ..sort((a, b) => used(b).compareTo(used(a)));
    for (final d in dirs.skip(8)) {
      if (d.path != keep) d.deleteSync(recursive: true);
    }
  } catch (_) {}
}

// ---------- EPUB hecho solo de imágenes (manga/manhua en EPUB) ----------

final _attrRe = RegExp(r'''([\w:.-]+)\s*=\s*(?:"([^"]*)"|'([^']*)')''');
final _fullPathRe = RegExp(r'''full-path\s*=\s*["']([^"']+)["']''');
final _itemRe = RegExp(r'<(?:\w+:)?item\s[^>]*>');
final _itemrefRe = RegExp(r'<(?:\w+:)?itemref\s[^>]*>');
final _imgRe = RegExp(r'<(?:\w+:)?(?:img|image)\s[^>]*>', caseSensitive: false);

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

List<ArchiveFile> _epubImages(Archive archive) {
  final byLower = <String, ArchiveFile>{};
  for (final f in archive.files) {
    if (f.isFile) byLower[f.name.toLowerCase()] = f;
  }
  ArchiveFile? find(String name) => byLower[name.toLowerCase()];
  String read(ArchiveFile f) => utf8.decode(f.content, allowMalformed: true);

  final container = find('META-INF/container.xml');
  final opfPath =
      container == null ? '' : (_fullPathRe.firstMatch(read(container))?.group(1) ?? '');
  final opf = opfPath.isEmpty ? null : find(opfPath);
  final out = <ArchiveFile>[];
  final seen = <String>{};
  if (opf != null) {
    final xml = read(opf);
    final slash = opfPath.lastIndexOf('/');
    final base = slash >= 0 ? opfPath.substring(0, slash + 1) : '';
    final manifest = <String, String>{};
    for (final m in _itemRe.allMatches(xml)) {
      final a = _attrs(m.group(0)!);
      final id = a['id'];
      final href = a['href'];
      if (id != null && href != null) manifest[id] = href;
    }
    for (final m in _itemrefRe.allMatches(xml)) {
      final href = manifest[_attrs(m.group(0)!)['idref']];
      if (href == null) continue;
      final chapter = _resolve(base, href);
      final f = find(chapter);
      if (f == null) continue;
      if (isImagePath(chapter)) {
        if (seen.add(f.name)) out.add(f);
        continue;
      }
      final cslash = chapter.lastIndexOf('/');
      final cbase = cslash >= 0 ? chapter.substring(0, cslash + 1) : '';
      for (final im in _imgRe.allMatches(read(f))) {
        final a = _attrs(im.group(0)!);
        final src = a['src'] ?? a['xlink:href'] ?? a['href'];
        if (src == null) continue;
        final img = find(_resolve(cbase, src));
        if (img != null && seen.add(img.name)) out.add(img);
      }
    }
  }
  if (out.isEmpty) return _zipImages(archive);
  return out;
}
