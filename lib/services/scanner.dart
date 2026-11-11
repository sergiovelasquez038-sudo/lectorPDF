import 'dart:io';
import 'dart:isolate';

import '../models.dart';

/// Busca documentos en todo el almacenamiento del teléfono.
/// Corre en un hilo aparte para que la pantalla no se congele.
/// [extraRoots] son carpetas adicionales (p. ej. la de archivos recibidos).
Future<List<DocItem>> scanDevice({List<String> extraRoots = const []}) {
  final extras = List<String>.of(extraRoots);
  return Isolate.run(() => _scanSync(extras));
}

List<DocItem> _scanSync(List<String> extraRoots) {
  final roots = <String>[];
  const primary = '/storage/emulated/0';
  if (Directory(primary).existsSync()) roots.add(primary);

  // Tarjetas SD y memorias USB aparecen como /storage/XXXX-XXXX
  try {
    for (final e in Directory('/storage').listSync(followLinks: false)) {
      final name = e.path.substring(e.path.lastIndexOf('/') + 1);
      if (e is Directory && name != 'emulated' && name != 'self') {
        roots.add(e.path);
      }
    }
  } catch (_) {
    // Sin acceso a /storage: seguimos solo con la memoria principal.
  }

  final out = <DocItem>[];
  final seen = <String>{};
  for (final root in roots) {
    _walk(Directory(root), out, seen, 0);
  }
  for (final root in extraRoots) {
    if (Directory(root).existsSync()) _walk(Directory(root), out, seen, 1);
  }
  return out;
}

// Carpetas que suelen guardar manhua/manga (Mihon, Tachiyomi, Kotatsu…)
// o con nombre de capítulo. Así no se confunden con las fotos del teléfono.
final _comicPathRe = RegExp(
    r'manhua|manhwa|manga|comic|cómic|webtoon|mihon|tachiyomi|kotatsu|komikku|mangayomi',
    caseSensitive: false);
final _chapterNameRe = RegExp(
    r'cap[ií]tulo|chapter|\bch\.?\s*\d|\bcap\.?\s*\d|episod|\bep\.?\s*\d',
    caseSensitive: false);

void _walk(Directory dir, List<DocItem> out, Set<String> seen, int depth) {
  if (depth > 16) return;

  List<FileSystemEntity> entries;
  try {
    entries = dir.listSync(followLinks: false);
  } catch (_) {
    return; // Carpeta protegida: la saltamos.
  }

  final dirName = dir.path.substring(dir.path.lastIndexOf('/') + 1);
  final comicContext = depth > 0 &&
      (_comicPathRe.hasMatch(dir.path) || _chapterNameRe.hasMatch(dirName));
  var images = 0;

  for (final e in entries) {
    final name = e.path.substring(e.path.lastIndexOf('/') + 1);
    if (name.startsWith('.')) continue; // carpetas y archivos ocultos

    if (e is Directory) {
      if (depth == 0 && name == 'Android') {
        // Android/data y Android/obb están bloqueadas, pero Android/media
        // guarda los documentos de WhatsApp y otras apps.
        final media = Directory('${e.path}/media');
        if (media.existsSync()) _walk(media, out, seen, depth + 2);
        continue;
      }
      _walk(e, out, seen, depth + 1);
    } else if (e is File) {
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot).toLowerCase();
      if (comicContext && kImageExtensions.contains(ext)) {
        images++;
        continue;
      }
      final type = kExtensions[ext];
      if (type == null) continue;
      try {
        final st = e.statSync();
        if (st.size == 0) continue;
        // Muchos TXT diminutos son archivos internos de apps, no lecturas.
        if (type == DocType.txt && st.size < 512) continue;
        if (seen.add(e.path)) {
          out.add(DocItem(
            path: e.path,
            size: st.size,
            modifiedMs: st.modified.millisecondsSinceEpoch,
          ));
        }
      } catch (_) {}
    }
  }

  // Carpeta con las imágenes de un capítulo.
  if (comicContext && images >= 3 && seen.add(dir.path)) {
    var modified = DateTime.now().millisecondsSinceEpoch;
    try {
      modified = dir.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {}
    out.add(DocItem(
      path: dir.path,
      size: images,
      modifiedMs: modified,
      isFolder: true,
    ));
  }
}
