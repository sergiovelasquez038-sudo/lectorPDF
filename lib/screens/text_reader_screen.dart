import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../navigation.dart';
import '../services/annotations_store.dart';
import '../services/extractors.dart';
import '../services/library_store.dart';
import '../services/pdf_text.dart';
import '../services/read_aloud.dart';
import '../services/reader_settings.dart';
import '../services/system_bridge.dart';
import '../services/text_tools.dart';
import '../widgets/read_aloud_bar.dart';
import '../widgets/voice_picker_sheet.dart';
import 'settings_screen.dart';

/// Lector para EPUB, Word, TXT y el "modo lectura" de los PDF:
/// el texto se adapta a la pantalla y se puede escuchar en voz alta.
class TextReaderScreen extends StatefulWidget {
  const TextReaderScreen({
    super.key,
    required this.doc,
    this.reflow,
    this.startPage,
  });

  final DocItem doc;

  /// Texto ya extraído de un PDF (modo lectura).
  final ReflowDoc? reflow;

  /// Página del PDF donde empezar (modo lectura).
  final int? startPage;

  @override
  State<TextReaderScreen> createState() => _TextReaderScreenState();
}

class _Mark {
  const _Mark(this.start, this.end, this.style);

  final int start;
  final int end;
  final TextStyle style;
}

/// Construye el texto con partes resaltadas (búsqueda, frase y palabra).
TextSpan _markedSpan(String text, TextStyle base, List<_Mark> marks) {
  if (marks.isEmpty) return TextSpan(text: text, style: base);
  final cuts = <int>{0, text.length};
  for (final m in marks) {
    cuts.add(m.start.clamp(0, text.length).toInt());
    cuts.add(m.end.clamp(0, text.length).toInt());
  }
  final points = cuts.toList()..sort();
  final children = <TextSpan>[];
  for (var k = 0; k + 1 < points.length; k++) {
    final a = points[k];
    final b = points[k + 1];
    if (b <= a) continue;
    TextStyle? style;
    for (final m in marks) {
      if (m.start <= a && m.end >= b) {
        style = style == null ? m.style : style.merge(m.style);
      }
    }
    children.add(TextSpan(text: text.substring(a, b), style: style));
  }
  return TextSpan(style: base, children: children);
}

class _TextReaderScreenState extends State<TextReaderScreen> {
  final store = LibraryStore.instance;
  final settings = ReaderSettings.instance;
  final notes = AnnotationsStore.instance;
  final _scroll = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _current = ValueNotifier<int>(0);
  final _searchCtrl = TextEditingController();

  ParsedDoc? _doc;
  Object? _error;
  int _initialIndex = 0;
  double? _dragValue;
  ReadAloudController? _reader;

  bool _showSearch = false;
  String _query = '';
  List<int> _hits = const [];
  int _hitPos = -1;
  bool _immersive = false;

  String get _key =>
      widget.reflow != null ? '${widget.doc.path}#reflow' : widget.doc.path;

  @override
  void initState() {
    super.initState();
    final reflow = widget.reflow;
    final startPage = widget.startPage;
    if (reflow != null && startPage != null) {
      _initialIndex = reflow.blockForPage(startPage);
    } else {
      _initialIndex = store.progress[_key]?.position ?? 0;
    }
    _current.value = _initialIndex;
    _positions.itemPositions.addListener(_onPositions);
    if (settings.keepScreenOn) SystemBridge.keepScreenOn(true);
    if (reflow != null) {
      _setDoc(reflow.doc);
      WidgetsBinding.instance.addPostFrameCallback((_) => _save());
    } else {
      _load();
    }
  }

  @override
  void dispose() {
    _positions.itemPositions.removeListener(_onPositions);
    _reader?.dispose();
    _current.dispose();
    _searchCtrl.dispose();
    store.flush();
    SystemBridge.keepScreenOn(false);
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  void _setDoc(ParsedDoc d) {
    _doc = d;
    _initialIndex =
        _initialIndex.clamp(0, math.max(0, d.blocks.length - 1)).toInt();
    _current.value = _initialIndex;
    _reader = ReadAloudController(
      title: widget.doc.name,
      itemCount: d.blocks.length,
      loadItem: (i) async => d.blocks[i].text,
      onItemStart: _follow,
      onMessage: showMessage,
    );
  }

  Future<void> _load() async {
    try {
      final d = await loadTextDocument(widget.doc.path, widget.doc.type);
      if (!mounted) return;
      setState(() => _setDoc(d));
      _save();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Detecta qué párrafo está arriba en la pantalla para recordar la posición.
  void _onPositions() {
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;
    var first = -1;
    for (final p in positions) {
      if (p.itemTrailingEdge > 0.02 && (first < 0 || p.index < first)) {
        first = p.index;
      }
    }
    if (first < 0 || first == _current.value) return;
    _current.value = first;
    _save();
  }

  void _save() {
    final d = _doc;
    if (d == null || d.blocks.isEmpty) return;
    final n = d.blocks.length;
    final i = _current.value.clamp(0, n - 1).toInt();
    store.saveProgress(_key, i, n <= 1 ? 1.0 : i / (n - 1));
    // En modo lectura, también guarda la página del PDF.
    final reflow = widget.reflow;
    if (reflow != null && i < reflow.blockPages.length) {
      final page = reflow.blockPages[i];
      final total = reflow.pageCount;
      store.saveProgress(
          widget.doc.path, page, total <= 1 ? 1.0 : (page - 1) / (total - 1));
    }
  }

  void _jump(int index) {
    final d = _doc;
    if (d == null || !_scroll.isAttached) return;
    final i = index.clamp(0, d.blocks.length - 1).toInt();
    _scroll.jumpTo(index: i, alignment: 0.05);
    _current.value = i;
    _save();
  }

  /// Mientras lee en voz alta, mantiene a la vista el párrafo que suena.
  void _follow(int i) {
    if (!mounted || !_scroll.isAttached) return;
    ItemPosition? pos;
    for (final p in _positions.itemPositions.value) {
      if (p.index == i) {
        pos = p;
        break;
      }
    }
    final visible =
        pos != null && pos.itemLeadingEdge >= 0 && pos.itemLeadingEdge < 0.7;
    if (!visible) {
      _scroll.scrollTo(
        index: i,
        alignment: 0.1,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  Future<void> _listen() async {
    final r = _reader;
    if (r == null) return;
    if (r.isActive) {
      r.togglePlay(r.item);
      return;
    }
    await askVoiceOnce(context);
    if (!mounted) return;
    r.playFrom(_current.value);
  }

  void _toggleImmersive() {
    setState(() => _immersive = !_immersive);
    SystemChrome.setEnabledSystemUIMode(
        _immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  // ---------- Búsqueda ----------

  void _runSearch(String text) {
    final d = _doc;
    final q = text.trim();
    if (d == null) return;
    if (q.isEmpty) {
      setState(() {
        _query = '';
        _hits = const [];
        _hitPos = -1;
      });
      return;
    }
    final fq = foldText(q);
    final hits = <int>[];
    for (var i = 0; i < d.blocks.length; i++) {
      if (foldText(d.blocks[i].text).contains(fq)) hits.add(i);
    }
    var pos = hits.indexWhere((i) => i >= _current.value);
    if (pos < 0 && hits.isNotEmpty) pos = 0;
    setState(() {
      _query = q;
      _hits = hits;
      _hitPos = pos;
    });
    if (pos >= 0) {
      _jump(hits[pos]);
    } else {
      showMessage('No se encontró "$q"');
    }
  }

  void _nextHit(int step) {
    if (_hits.isEmpty) return;
    setState(() => _hitPos = (_hitPos + step) % _hits.length);
    _jump(_hits[_hitPos]);
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _query = '';
        _hits = const [];
        _hitPos = -1;
        _searchCtrl.clear();
      }
    });
  }

  List<_Mark> _searchMarks(String text) {
    if (_query.isEmpty) return const [];
    final folded = foldText(text);
    final q = foldText(_query);
    if (folded.length != text.length || q.isEmpty) return const [];
    const style =
        TextStyle(backgroundColor: Color(0xFFFFE082), color: Color(0xFF000000));
    final out = <_Mark>[];
    var start = 0;
    while (true) {
      final i = folded.indexOf(q, start);
      if (i < 0) break;
      out.add(_Mark(i, i + q.length, style));
      start = i + q.length;
    }
    return out;
  }

  // ---------- Marcadores, subrayados y notas ----------

  void _toggleBookmark(int i) {
    final d = _doc;
    if (d == null || d.blocks.isEmpty) return;
    final index = i.clamp(0, d.blocks.length - 1).toInt();
    final added =
        notes.toggleBookmark(_key, index, excerpt(d.blocks[index].text, 70));
    showMessage(added ? 'Marcador agregado.' : 'Marcador quitado.');
  }

  void _setColor(int i, int color) {
    final d = _doc;
    if (d == null) return;
    final existing = notes.highlightAt(_key, i);
    notes.saveHighlight(
      _key,
      existing?.copyWith(color: color) ??
          Highlight(
            index: i,
            color: color,
            excerpt: excerpt(d.blocks[i].text, 120),
            createdMs: DateTime.now().millisecondsSinceEpoch,
          ),
    );
  }

  Future<void> _editNote(int i) async {
    final d = _doc;
    if (d == null) return;
    final existing = notes.highlightAt(_key, i);
    final ctrl = TextEditingController(text: existing?.note ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Nota'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          minLines: 3,
          maxLines: 6,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Escribe tu nota…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Guardar'),
          ),
        ],
      ),
    );
    if (result == null) return;
    final base = existing ??
        Highlight(
          index: i,
          color: 0,
          excerpt: excerpt(d.blocks[i].text, 120),
          createdMs: DateTime.now().millisecondsSinceEpoch,
        );
    notes.saveHighlight(_key, base.copyWith(note: result.trim()));
  }

  void _paragraphMenu(int i) {
    final d = _doc;
    if (d == null) return;
    final block = d.blocks[i];
    final hl = notes.highlightAt(_key, i);
    final bookmarked = notes.hasBookmark(_key, i);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) {
        final t = Theme.of(ctx).textTheme;
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  excerpt(block.text, 160),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: t.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
                ),
                const SizedBox(height: 16),
                Text('Subrayar', style: t.titleSmall),
                const SizedBox(height: 8),
                Row(
                  children: [
                    for (final c in kHighlightColors)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () {
                            Navigator.pop(ctx);
                            _setColor(i, c);
                          },
                          child: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: Color(c),
                              shape: BoxShape.circle,
                              border: Border.all(
                                width: hl?.color == c ? 3 : 1,
                                color: hl?.color == c
                                    ? Colors.black54
                                    : Colors.black12,
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (hl != null && hl.color != 0)
                      IconButton(
                        tooltip: 'Quitar subrayado',
                        icon: const Icon(Icons.format_color_reset_rounded),
                        onPressed: () {
                          Navigator.pop(ctx);
                          _setColor(i, 0);
                        },
                      ),
                  ],
                ),
                const Divider(height: 28),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.headphones_rounded),
                  title: const Text('Escuchar desde aquí'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _reader?.playFrom(i);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.edit_note_rounded),
                  title: Text((hl?.note ?? '').isNotEmpty ? 'Editar nota' : 'Agregar nota'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _editNote(i);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(bookmarked
                      ? Icons.bookmark_remove_rounded
                      : Icons.bookmark_add_rounded),
                  title: Text(bookmarked ? 'Quitar marcador' : 'Poner marcador aquí'),
                  onTap: () {
                    Navigator.pop(ctx);
                    _toggleBookmark(i);
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.copy_rounded),
                  title: const Text('Copiar texto'),
                  onTap: () {
                    Navigator.pop(ctx);
                    Clipboard.setData(ClipboardData(text: block.text));
                    showMessage('Texto copiado.');
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.share_rounded),
                  title: const Text('Compartir texto'),
                  onTap: () {
                    Navigator.pop(ctx);
                    SharePlus.instance.share(ShareParams(text: block.text));
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.55,
        maxChildSize: 0.92,
        builder: (ctx, sc) => ListenableBuilder(
          listenable: notes,
          builder: (ctx, _) {
            final list = notes.bookmarksFor(_key);
            final n = math.max(1, (_doc?.blocks.length ?? 1) - 1);
            if (list.isEmpty) {
              return ListView(
                controller: sc,
                padding: const EdgeInsets.all(24),
                children: const [
                  Text(
                    'Aún no tienes marcadores.\n\nMantén presionado un párrafo '
                    'y elige "Poner marcador aquí".',
                    textAlign: TextAlign.center,
                  ),
                ],
              );
            }
            return ListView.builder(
              controller: sc,
              itemCount: list.length,
              itemBuilder: (ctx, k) {
                final b = list[k];
                return ListTile(
                  leading: const Icon(Icons.bookmark_rounded),
                  title: Text(b.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${(b.position * 100 / n).round().clamp(0, 100)}%'),
                  trailing: IconButton(
                    tooltip: 'Eliminar',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () => notes.removeBookmark(_key, b.position),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _jump(b.position);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  void _shareNotes(List<Highlight> list) {
    final buf = StringBuffer('Notas de "${widget.doc.name}"\n');
    for (final h in list) {
      buf.write('\n• "${h.excerpt}"\n');
      if (h.note.trim().isNotEmpty) buf.write('  Nota: ${h.note.trim()}\n');
    }
    SharePlus.instance.share(ShareParams(
      text: buf.toString(),
      subject: 'Notas de ${widget.doc.name}',
    ));
  }

  void _showNotes() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.92,
        builder: (ctx, sc) => ListenableBuilder(
          listenable: notes,
          builder: (ctx, _) {
            final list = notes.highlightsFor(_key);
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('Notas y subrayados (${list.length})',
                            style: Theme.of(ctx).textTheme.titleMedium),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.share_rounded),
                        label: const Text('Compartir'),
                        onPressed: list.isEmpty ? null : () => _shareNotes(list),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: list.isEmpty
                      ? ListView(
                          controller: sc,
                          padding: const EdgeInsets.all(24),
                          children: const [
                            Text(
                              'Mantén presionado un párrafo para subrayarlo '
                              'o escribir una nota.',
                              textAlign: TextAlign.center,
                            ),
                          ],
                        )
                      : ListView.builder(
                          controller: sc,
                          itemCount: list.length,
                          itemBuilder: (ctx, k) {
                            final h = list[k];
                            return ListTile(
                              leading: h.color == 0
                                  ? const Icon(Icons.sticky_note_2_outlined)
                                  : Container(
                                      width: 18,
                                      height: 18,
                                      decoration: BoxDecoration(
                                        color: Color(h.color),
                                        shape: BoxShape.circle,
                                      ),
                                    ),
                              title: Text(h.excerpt,
                                  maxLines: 2, overflow: TextOverflow.ellipsis),
                              subtitle: h.note.trim().isEmpty
                                  ? null
                                  : Text(h.note,
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis),
                              trailing: IconButton(
                                tooltip: 'Eliminar',
                                icon: const Icon(Icons.delete_outline_rounded),
                                onPressed: () => notes.removeHighlight(_key, h.index),
                              ),
                              onTap: () {
                                Navigator.pop(ctx);
                                _jump(h.index);
                              },
                            );
                          },
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _onMenu(String value) {
    switch (value) {
      case 'toc':
        _showToc();
      case 'bookmark':
        _toggleBookmark(_current.value);
      case 'bookmarks':
        _showBookmarks();
      case 'notes':
        _showNotes();
      case 'voices':
        showVoicePicker(context);
      case 'settings':
        Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      case 'fullscreen':
        _toggleImmersive();
    }
  }

  // ---------- Pantalla ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, notes]),
      builder: (context, _) {
        final bg = settings.background;
        final fg = settings.foreground;
        final d = _doc;
        final title = widget.reflow != null
            ? '${widget.doc.name} · lectura'
            : widget.doc.name;
        return Scaffold(
          backgroundColor: bg,
          appBar: _immersive
              ? null
              : AppBar(
                  backgroundColor: bg,
                  foregroundColor: fg,
                  surfaceTintColor: Colors.transparent,
                  title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
                  actions: [
                    IconButton(
                      tooltip: 'Escuchar',
                      icon: const Icon(Icons.headphones_rounded),
                      onPressed: d == null ? null : _listen,
                    ),
                    IconButton(
                      tooltip: 'Buscar',
                      icon: Icon(_showSearch ? Icons.search_off : Icons.search),
                      onPressed: d == null ? null : _toggleSearch,
                    ),
                    IconButton(
                      tooltip: 'Apariencia',
                      icon: const Icon(Icons.text_fields_rounded),
                      onPressed: _showAppearance,
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Más',
                      enabled: d != null,
                      onSelected: _onMenu,
                      itemBuilder: (_) => [
                        if ((d?.toc.length ?? 0) > 1)
                          const PopupMenuItem(
                            value: 'toc',
                            child: ListTile(
                              leading: Icon(Icons.toc_rounded),
                              title: Text('Índice'),
                            ),
                          ),
                        PopupMenuItem(
                          value: 'bookmark',
                          child: ListTile(
                            leading: Icon(notes.hasBookmark(_key, _current.value)
                                ? Icons.bookmark_remove_rounded
                                : Icons.bookmark_add_rounded),
                            title: Text(notes.hasBookmark(_key, _current.value)
                                ? 'Quitar marcador'
                                : 'Marcador aquí'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'bookmarks',
                          child: ListTile(
                            leading: Icon(Icons.bookmarks_rounded),
                            title: Text('Marcadores'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'notes',
                          child: ListTile(
                            leading: Icon(Icons.border_color_rounded),
                            title: Text('Notas y subrayados'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'voices',
                          child: ListTile(
                            leading: Icon(Icons.record_voice_over_rounded),
                            title: Text('Cambiar voz'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'settings',
                          child: ListTile(
                            leading: Icon(Icons.settings_rounded),
                            title: Text('Configuración'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'fullscreen',
                          child: ListTile(
                            leading: Icon(Icons.fullscreen_rounded),
                            title: Text('Pantalla completa'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  bottom: _showSearch ? _searchBar(fg) : null,
                ),
          body: SafeArea(top: _immersive, bottom: false, child: _body(fg)),
          bottomNavigationBar: d == null ? null : _bottomBar(d, fg, bg),
        );
      },
    );
  }

  Widget _body(Color fg) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'No se pudo abrir este documento.\n\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: fg),
          ),
        ),
      );
    }
    final d = _doc;
    final reader = _reader;
    if (d == null || reader == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (d.blocks.isEmpty) {
      return Center(
        child: Text('Este documento no tiene texto para mostrar.',
            style: TextStyle(color: fg)),
      );
    }
    final base = TextStyle(
      fontSize: settings.fontSize,
      height: settings.lineHeight,
      color: fg,
      fontFamily: settings.serif ? 'serif' : null,
    );
    return GestureDetector(
      onTap: _toggleImmersive,
      child: ListenableBuilder(
        listenable: reader,
        builder: (context, _) => ScrollablePositionedList.builder(
          itemCount: d.blocks.length,
          itemScrollController: _scroll,
          itemPositionsListener: _positions,
          initialScrollIndex: _initialIndex,
          padding: const EdgeInsets.fromLTRB(22, 8, 22, 48),
          itemBuilder: (context, i) => _blockView(i, d.blocks[i], base),
        ),
      ),
    );
  }

  Widget _blockView(int i, TextBlock b, TextStyle base) {
    final size = settings.fontSize;
    final style = b.isHeading
        ? base.copyWith(
            fontSize: size * (b.level == 1 ? 1.45 : (b.level == 2 ? 1.25 : 1.1)),
            fontWeight: FontWeight.bold,
            height: 1.3,
          )
        : base;

    final marks = <_Mark>[];
    final reader = _reader;
    if (reader != null && reader.isActive && reader.item == i) {
      final s = reader.sentence;
      if (s != null) {
        marks.add(_Mark(s.start, s.end,
            TextStyle(backgroundColor: settings.sentenceColor)));
      }
      final ws = reader.wordStart;
      final we = reader.wordEnd;
      if (ws != null && we != null && we > ws) {
        marks.add(_Mark(ws, we, TextStyle(backgroundColor: settings.wordColor)));
      }
    }
    marks.addAll(_searchMarks(b.text));

    Widget content = Text.rich(_markedSpan(b.text, style, marks));

    final hl = notes.highlightAt(_key, i);
    if (hl != null) {
      final note = hl.note.trim();
      content = Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: hl.color == 0
              ? null
              : Color(hl.color).withValues(alpha: settings.isDark ? 0.28 : 0.5),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            content,
            if (note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.sticky_note_2_outlined,
                        size: 18, color: settings.foreground.withValues(alpha: 0.7)),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        note,
                        style: TextStyle(
                          color: settings.foreground.withValues(alpha: 0.8),
                          fontSize: size * 0.8,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    }

    if (notes.hasBookmark(_key, i)) {
      content = Stack(
        clipBehavior: Clip.none,
        children: [
          content,
          Positioned(
            top: -2,
            right: -20,
            child: Icon(Icons.bookmark_rounded,
                size: 18, color: Theme.of(context).colorScheme.primary),
          ),
        ],
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: () => _paragraphMenu(i),
      child: Padding(
        padding: b.isHeading
            ? EdgeInsets.only(top: size * 1.4, bottom: size * 0.7)
            : EdgeInsets.only(bottom: size * 0.8),
        child: content,
      ),
    );
  }

  PreferredSizeWidget _searchBar(Color fg) {
    final status = _hits.isEmpty
        ? (_query.isEmpty ? '' : '0')
        : '${_hitPos + 1}/${_hits.length}';
    return PreferredSize(
      preferredSize: const Size.fromHeight(60),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 4, 10),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                autofocus: true,
                style: TextStyle(color: fg),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Buscar en el texto',
                  hintStyle: TextStyle(color: fg.withValues(alpha: 0.5)),
                  isDense: true,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: _runSearch,
              ),
            ),
            const SizedBox(width: 10),
            Text(status, style: TextStyle(color: fg)),
            IconButton(
              tooltip: 'Anterior',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: _hits.isEmpty ? null : () => _nextHit(-1),
            ),
            IconButton(
              tooltip: 'Siguiente',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: _hits.isEmpty ? null : () => _nextHit(1),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar(ParsedDoc d, Color fg, Color bg) {
    final reader = _reader;
    if (reader == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: reader,
      builder: (context, _) {
        if (reader.isActive) {
          return ReadAloudBar(controller: reader, background: bg, foreground: fg);
        }
        if (_immersive || d.blocks.length < 2) return const SizedBox.shrink();
        return _progressBar(d, fg, bg);
      },
    );
  }

  Widget _progressBar(ParsedDoc d, Color fg, Color bg) {
    final n = d.blocks.length;
    return Material(
      color: bg,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 16, 2),
          // Altura fija: sin ella el Slider se estira y tapa toda la pantalla.
          child: SizedBox(
            height: 52,
            child: ValueListenableBuilder<int>(
            valueListenable: _current,
            builder: (context, cur, _) {
              final v = (_dragValue ?? cur.toDouble())
                  .clamp(0.0, (n - 1).toDouble())
                  .toDouble();
              final pct = ((v / (n - 1)) * 100).round();
              return Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: v,
                      min: 0,
                      max: (n - 1).toDouble(),
                      onChanged: (x) => setState(() => _dragValue = x),
                      onChangeEnd: (x) {
                        setState(() => _dragValue = null);
                        _jump(x.round());
                      },
                    ),
                  ),
                  SizedBox(
                    width: 44,
                    child: Text('$pct%',
                        textAlign: TextAlign.end, style: TextStyle(color: fg)),
                  ),
                ],
              );
            },
            ),
          ),
        ),
      ),
    );
  }

  void _showToc() {
    final d = _doc;
    if (d == null) return;
    var currentEntry = 0;
    for (var i = 0; i < d.toc.length; i++) {
      if (d.toc[i].index <= _current.value) currentEntry = i;
    }
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        maxChildSize: 0.95,
        builder: (ctx, sc) => ListView.builder(
          controller: sc,
          itemCount: d.toc.length,
          itemBuilder: (ctx, i) {
            final e = d.toc[i];
            return ListTile(
              selected: i == currentEntry,
              contentPadding:
                  EdgeInsets.only(left: 16.0 + (e.level - 1) * 18, right: 16),
              title: Text(e.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              onTap: () {
                Navigator.pop(ctx);
                _jump(e.index);
              },
            );
          },
        ),
      ),
    );
  }

  void _showAppearance() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => ListenableBuilder(
        listenable: settings,
        builder: (ctx, _) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Tamaño de letra: ${settings.fontSize.round()}'),
                Row(
                  children: [
                    const Icon(Icons.text_decrease, size: 20),
                    Expanded(
                      child: Slider(
                        value: settings.fontSize,
                        min: 14,
                        max: 32,
                        divisions: 18,
                        onChanged: settings.setFontSize,
                      ),
                    ),
                    const Icon(Icons.text_increase, size: 24),
                  ],
                ),
                Text('Interlineado: ${settings.lineHeight.toStringAsFixed(1)}'),
                Slider(
                  value: settings.lineHeight,
                  min: 1.2,
                  max: 2.0,
                  divisions: 8,
                  onChanged: settings.setLineHeight,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<ReaderTheme>(
                    segments: [
                      for (final t in ReaderTheme.values)
                        ButtonSegment<ReaderTheme>(value: t, label: Text(t.label)),
                    ],
                    selected: {settings.theme},
                    onSelectionChanged: (s) => settings.setTheme(s.first),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Letra con serifa (tipo libro)'),
                  value: settings.serif,
                  onChanged: settings.setSerif,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Mantener la pantalla encendida'),
                  value: settings.keepScreenOn,
                  onChanged: (v) {
                    settings.setKeepScreenOn(v);
                    SystemBridge.keepScreenOn(v);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
