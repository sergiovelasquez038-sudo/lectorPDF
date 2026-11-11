import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Colores para subrayar (amarillo, verde, azul, rosa).
const kHighlightColors = <int>[0xFFFFE082, 0xFFA5D6A7, 0xFF90CAF9, 0xFFF48FB1];

/// Marcador: una página (PDF) o un párrafo (EPUB, Word, TXT).
class Bookmark {
  const Bookmark({
    required this.position,
    required this.label,
    required this.createdMs,
  });

  final int position;
  final String label;
  final int createdMs;

  Map<String, dynamic> toJson() => {'p': position, 'l': label, 'c': createdMs};

  static Bookmark fromJson(Map<String, dynamic> j) => Bookmark(
        position: (j['p'] as num).toInt(),
        label: j['l'] as String? ?? '',
        createdMs: (j['c'] as num?)?.toInt() ?? 0,
      );
}

/// Subrayado y/o nota sobre un párrafo.
/// [color] 0 significa "solo nota, sin color".
class Highlight {
  const Highlight({
    required this.index,
    required this.color,
    this.note = '',
    this.excerpt = '',
    required this.createdMs,
  });

  final int index;
  final int color;
  final String note;
  final String excerpt;
  final int createdMs;

  bool get isEmpty => color == 0 && note.trim().isEmpty;

  Highlight copyWith({int? color, String? note}) => Highlight(
        index: index,
        color: color ?? this.color,
        note: note ?? this.note,
        excerpt: excerpt,
        createdMs: createdMs,
      );

  Map<String, dynamic> toJson() =>
      {'i': index, 'k': color, 'n': note, 'e': excerpt, 'c': createdMs};

  static Highlight fromJson(Map<String, dynamic> j) => Highlight(
        index: (j['i'] as num).toInt(),
        color: (j['k'] as num?)?.toInt() ?? 0,
        note: j['n'] as String? ?? '',
        excerpt: j['e'] as String? ?? '',
        createdMs: (j['c'] as num?)?.toInt() ?? 0,
      );
}

/// Guarda marcadores, subrayados y notas de cada documento.
class AnnotationsStore extends ChangeNotifier {
  AnnotationsStore._();
  static final AnnotationsStore instance = AnnotationsStore._();

  SharedPreferences? _prefs;
  final Map<String, List<Bookmark>> _bookmarks = {};
  final Map<String, Map<int, Highlight>> _highlights = {};

  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _prefs = prefs;
    try {
      final rawB = prefs.getString('bookmarks');
      if (rawB != null) {
        (jsonDecode(rawB) as Map).forEach((key, value) {
          _bookmarks[key as String] = (value as List)
              .map((e) => Bookmark.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList();
        });
      }
      final rawH = prefs.getString('highlights');
      if (rawH != null) {
        (jsonDecode(rawH) as Map).forEach((key, value) {
          final map = <int, Highlight>{};
          for (final e in value as List) {
            final h = Highlight.fromJson(Map<String, dynamic>.from(e as Map));
            map[h.index] = h;
          }
          _highlights[key as String] = map;
        });
      }
    } catch (e) {
      debugPrint('No se pudieron leer las notas guardadas: $e');
    }
  }

  void _save() {
    final prefs = _prefs;
    if (prefs == null) return;
    prefs.setString(
      'bookmarks',
      jsonEncode(_bookmarks.map(
          (k, v) => MapEntry(k, v.map((b) => b.toJson()).toList()))),
    );
    prefs.setString(
      'highlights',
      jsonEncode(_highlights.map(
          (k, v) => MapEntry(k, v.values.map((h) => h.toJson()).toList()))),
    );
  }

  // ---------- Marcadores ----------

  List<Bookmark> bookmarksFor(String key) {
    final list = List<Bookmark>.of(_bookmarks[key] ?? const <Bookmark>[]);
    list.sort((a, b) => a.position.compareTo(b.position));
    return list;
  }

  bool hasBookmark(String key, int position) =>
      _bookmarks[key]?.any((b) => b.position == position) ?? false;

  /// Agrega o quita un marcador. Devuelve true si quedó agregado.
  bool toggleBookmark(String key, int position, String label) {
    final list = _bookmarks.putIfAbsent(key, () => <Bookmark>[]);
    final existed = list.any((b) => b.position == position);
    if (existed) {
      list.removeWhere((b) => b.position == position);
      if (list.isEmpty) _bookmarks.remove(key);
    } else {
      list.add(Bookmark(
        position: position,
        label: label,
        createdMs: DateTime.now().millisecondsSinceEpoch,
      ));
    }
    _save();
    notifyListeners();
    return !existed;
  }

  void removeBookmark(String key, int position) {
    final list = _bookmarks[key];
    if (list == null) return;
    list.removeWhere((b) => b.position == position);
    if (list.isEmpty) _bookmarks.remove(key);
    _save();
    notifyListeners();
  }

  // ---------- Subrayados y notas ----------

  Highlight? highlightAt(String key, int index) => _highlights[key]?[index];

  List<Highlight> highlightsFor(String key) {
    final list = (_highlights[key]?.values ?? const <Highlight>[]).toList();
    list.sort((a, b) => a.index.compareTo(b.index));
    return list;
  }

  void saveHighlight(String key, Highlight h) {
    if (h.isEmpty) {
      removeHighlight(key, h.index);
      return;
    }
    _highlights.putIfAbsent(key, () => <int, Highlight>{})[h.index] = h;
    _save();
    notifyListeners();
  }

  void removeHighlight(String key, int index) {
    final map = _highlights[key];
    if (map == null) return;
    map.remove(index);
    if (map.isEmpty) _highlights.remove(key);
    _save();
    notifyListeners();
  }

  // ---------- Cuando un archivo cambia de nombre o se borra ----------

  void renameDocument(String oldPath, String newPath) {
    for (final suffix in const ['', '#reflow']) {
      final b = _bookmarks.remove('$oldPath$suffix');
      if (b != null) _bookmarks['$newPath$suffix'] = b;
      final h = _highlights.remove('$oldPath$suffix');
      if (h != null) _highlights['$newPath$suffix'] = h;
    }
    _save();
    notifyListeners();
  }

  void removeDocument(String path) {
    for (final suffix in const ['', '#reflow']) {
      _bookmarks.remove('$path$suffix');
      _highlights.remove('$path$suffix');
    }
    _save();
    notifyListeners();
  }
}
