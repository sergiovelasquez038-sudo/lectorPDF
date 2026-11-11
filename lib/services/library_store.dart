import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:path/path.dart' as p;

import '../models.dart';
import 'annotations_store.dart';
import 'scanner.dart';
import 'system_bridge.dart';

enum SortMode {
  recent('Más recientes'),
  name('Nombre (A-Z)'),
  size('Tamaño');

  const SortMode(this.label);
  final String label;
}

/// Guarda la biblioteca: documentos encontrados, favoritos y progreso.
class LibraryStore extends ChangeNotifier {
  LibraryStore._();
  static final LibraryStore instance = LibraryStore._();

  late SharedPreferences _prefs;
  Timer? _saveTimer;

  List<DocItem> docs = [];
  final Map<String, ReadingProgress> progress = {};
  final Set<String> favorites = {};
  bool scanning = false;
  bool hasPermission = false;
  DateTime? lastScan;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
    try {
      final raw = _prefs.getString('docs');
      if (raw != null) {
        docs = (jsonDecode(raw) as List)
            .map((e) => DocItem.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList();
      }
      final rawProgress = _prefs.getString('progress');
      if (rawProgress != null) {
        (jsonDecode(rawProgress) as Map).forEach((key, value) {
          progress[key as String] = ReadingProgress.fromJson(
              Map<String, dynamic>.from(value as Map));
        });
      }
    } catch (e) {
      debugPrint('No se pudo leer la biblioteca guardada: $e');
    }
    favorites.addAll(_prefs.getStringList('favs') ?? const <String>[]);
    final ls = _prefs.getInt('lastScan');
    if (ls != null) lastScan = DateTime.fromMillisecondsSinceEpoch(ls);

    hasPermission = await checkPermission();
    notifyListeners();
    if (hasPermission) unawaited(scan());
  }

  // ---------- Permisos ----------

  static Future<bool> checkPermission() async {
    if (!Platform.isAndroid) return true;
    if (await Permission.manageExternalStorage.isGranted) return true;
    return Permission.storage.isGranted;
  }

  /// Android 11 o superior: abre la pantalla "Acceso a todos los archivos".
  /// Android 10 o inferior: muestra el permiso de almacenamiento clásico.
  Future<bool> requestPermission() async {
    var granted = (await Permission.manageExternalStorage.request()).isGranted;
    if (!granted) {
      granted = (await Permission.storage.request()).isGranted;
    }
    hasPermission = granted;
    notifyListeners();
    if (granted) unawaited(scan());
    return granted;
  }

  Future<void> recheckPermission() async {
    final before = hasPermission;
    hasPermission = await checkPermission();
    if (hasPermission != before) {
      notifyListeners();
      if (hasPermission) unawaited(scan());
    }
  }

  // ---------- Búsqueda de archivos ----------

  Future<void> scan() async {
    if (scanning) return;
    scanning = true;
    notifyListeners();
    try {
      final received = await SystemBridge.receivedDir();
      final found = await scanDevice(
          extraRoots: [if (received != null) received]);
      found.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      docs = found;
      lastScan = DateTime.now();
      await _saveDocs();
      await _prefs.setInt('lastScan', lastScan!.millisecondsSinceEpoch);
    } catch (e) {
      debugPrint('Error al buscar documentos: $e');
    } finally {
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> _saveDocs() =>
      _prefs.setString('docs', jsonEncode(docs.map((d) => d.toJson()).toList()));

  void removeDoc(String path) {
    docs = docs.where((d) => d.path != path).toList();
    notifyListeners();
    _saveDocs();
  }

  /// Agrega a la biblioteca un archivo recibido de otra app.
  DocItem? addFile(String path) {
    final item = DocItem.fromFile(path);
    if (item == null) return null;
    docs = [item, ...docs.where((d) => d.path != path)];
    notifyListeners();
    _saveDocs();
    return item;
  }

  /// Cambia el nombre del archivo en el teléfono. Devuelve un mensaje de
  /// error o null si salió bien.
  Future<String?> renameDoc(DocItem doc, String newName) async {
    final clean = newName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (clean.isEmpty) return 'Escribe un nombre.';
    final ext = p.extension(doc.path);
    final newPath = p.join(p.dirname(doc.path), '$clean$ext');
    if (newPath == doc.path) return null;
    if (File(newPath).existsSync()) return 'Ya existe un archivo con ese nombre.';
    try {
      await File(doc.path).rename(newPath);
    } catch (e) {
      return 'No se pudo cambiar el nombre.';
    }
    final updated = DocItem(
        path: newPath, size: doc.size, modifiedMs: doc.modifiedMs);
    docs = [for (final d in docs) d.path == doc.path ? updated : d];
    final prog = progress.remove(doc.path);
    if (prog != null) progress[newPath] = prog;
    final reflow = progress.remove('${doc.path}#reflow');
    if (reflow != null) progress['$newPath#reflow'] = reflow;
    if (favorites.remove(doc.path)) favorites.add(newPath);
    AnnotationsStore.instance.renameDocument(doc.path, newPath);
    await _saveDocs();
    await _prefs.setStringList('favs', favorites.toList());
    _persistProgress();
    notifyListeners();
    return null;
  }

  /// Borra el archivo del teléfono.
  Future<String?> deleteDoc(DocItem doc) async {
    try {
      final f = File(doc.path);
      if (f.existsSync()) await f.delete();
    } catch (e) {
      return 'No se pudo eliminar el archivo.';
    }
    docs = docs.where((d) => d.path != doc.path).toList();
    progress.remove(doc.path);
    progress.remove('${doc.path}#reflow');
    favorites.remove(doc.path);
    AnnotationsStore.instance.removeDocument(doc.path);
    await _saveDocs();
    await _prefs.setStringList('favs', favorites.toList());
    _persistProgress();
    notifyListeners();
    return null;
  }

  // ---------- Favoritos ----------

  bool isFavorite(String path) => favorites.contains(path);

  void toggleFavorite(String path) {
    if (!favorites.remove(path)) favorites.add(path);
    _prefs.setStringList('favs', favorites.toList());
    notifyListeners();
  }

  // ---------- Progreso de lectura ----------

  void saveProgress(String path, int position, double fraction) {
    progress[path] = ReadingProgress(
      position: position,
      fraction: fraction.clamp(0.0, 1.0).toDouble(),
      openedMs: DateTime.now().millisecondsSinceEpoch,
    );
    notifyListeners();
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 800), _persistProgress);
  }

  void flush() {
    _saveTimer?.cancel();
    _persistProgress();
  }

  void _persistProgress() {
    final map = progress.map((k, v) => MapEntry(k, v.toJson()));
    _prefs.setString('progress', jsonEncode(map));
  }

  /// Últimos documentos abiertos, para "Continuar leyendo".
  List<DocItem> get recent {
    final byPath = {for (final d in docs) d.path: d};
    final entries = progress.entries
        .where((e) => byPath.containsKey(e.key))
        .toList()
      ..sort((a, b) => b.value.openedMs.compareTo(a.value.openedMs));
    return entries.take(12).map((e) => byPath[e.key]!).toList();
  }
}
