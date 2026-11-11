import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../navigation.dart';
import '../services/annotations_store.dart';
import '../services/error_log.dart';
import '../services/library_store.dart';
import '../services/pdf_text.dart';
import '../services/read_aloud.dart';
import '../services/reader_settings.dart';
import '../services/system_bridge.dart';
import '../widgets/read_aloud_bar.dart';
import '../widgets/voice_picker_sheet.dart';
import 'settings_screen.dart';
import 'text_reader_screen.dart';

/// Invierte los colores de la página para leer de noche.
const _invertColors = ColorFilter.matrix(<double>[
  -1, 0, 0, 0, 255, //
  0, -1, 0, 0, 255, //
  0, 0, -1, 0, 255, //
  0, 0, 0, 1, 0, //
]);

const _normalColors = ColorFilter.mode(Colors.white, BlendMode.dst);

/// Páginas una al lado de la otra (se pasan deslizando de lado).
PdfPageLayout _horizontalLayout(List<PdfPage> pages, PdfViewerParams params) {
  final height = pages.fold<double>(0.0, (prev, page) => math.max(prev, page.height)) +
      params.margin * 2;
  final layouts = <Rect>[];
  var x = params.margin;
  for (final page in pages) {
    layouts.add(Rect.fromLTWH(x, (height - page.height) / 2, page.width, page.height));
    x += page.width + params.margin;
  }
  return PdfPageLayout(pageLayouts: layouts, documentSize: Size(x, height));
}

class PdfReaderScreen extends StatefulWidget {
  const PdfReaderScreen({super.key, required this.doc});

  final DocItem doc;

  @override
  State<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends State<PdfReaderScreen> {
  final store = LibraryStore.instance;
  final settings = ReaderSettings.instance;
  final notes = AnnotationsStore.instance;
  final controller = PdfViewerController();
  final _searchCtrl = TextEditingController();
  late final PdfTextSearcher _searcher;
  late final PdfTextSource _text;
  late final ReadAloudController _reader;
  late final int _initialPage;
  late bool _horizontal;
  late Widget _viewer;

  PdfDocument? _document;
  List<PdfOutlineNode> _outline = const [];
  int _page = 1;
  int _pageCount = 0;
  double? _dragValue;
  bool _showSearch = false;
  bool _immersive = false;

  @override
  void initState() {
    super.initState();
    _initialPage = math.max(1, store.progress[widget.doc.path]?.position ?? 1);
    _page = _initialPage;
    _searcher = PdfTextSearcher(controller)..addListener(_onSearchUpdate);
    _text = PdfTextSource(widget.doc.path);
    _reader = ReadAloudController(
      title: widget.doc.name,
      itemCount: 0,
      loadItem: _text.pageText,
      onItemStart: _onReadPage,
      onMessage: showMessage,
    );
    _horizontal = settings.pdfHorizontal;
    // El visor se guarda para no recrearlo en cada actualización de pantalla.
    _viewer = _buildViewer();
    if (settings.keepScreenOn) SystemBridge.keepScreenOn(true);
    ErrorLog.entries.addListener(_onAppError);
  }

  bool _errorShown = false;

  /// Si algo falla al dibujar el PDF, ofrece el modo lectura.
  void _onAppError() {
    if (_errorShown || !mounted) return;
    _errorShown = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showMessage(
        'Este PDF no se pudo dibujar bien. Prueba el modo lectura.',
        action: SnackBarAction(label: 'Modo lectura', onPressed: _openReflow),
      );
    });
  }

  @override
  void dispose() {
    ErrorLog.entries.removeListener(_onAppError);
    _searcher.removeListener(_onSearchUpdate);
    _searcher.dispose();
    _searchCtrl.dispose();
    _reader.dispose();
    _text.dispose();
    store.flush();
    SystemBridge.keepScreenOn(false);
    if (_immersive) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  Widget _buildViewer() => PdfViewer.file(
        widget.doc.path,
        controller: controller,
        initialPageNumber: _initialPage,
        passwordProvider: _askPassword,
        params: PdfViewerParams(
          backgroundColor: const Color(0xFFE4E4E4),
          maxScale: 8.0,
          layoutPages: _horizontal ? _horizontalLayout : null,
          onViewerReady: _onReady,
          onPageChanged: _onPageChanged,
          onGeneralTap: _onTap,
          pagePaintCallbacks: [_searcher.pageTextMatchPaintCallback],
        ),
      );

  void _onSearchUpdate() {
    if (mounted) setState(() {});
  }

  Future<String?> _askPassword() async {
    if (!mounted) return null;
    final ctrl = TextEditingController();
    final pwd = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('PDF protegido'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          obscureText: true,
          keyboardType: TextInputType.visiblePassword,
          decoration: const InputDecoration(labelText: 'Contraseña'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text),
            child: const Text('Abrir'),
          ),
        ],
      ),
    );
    if (pwd != null) _text.password = pwd;
    return pwd;
  }

  void _onReady(PdfDocument document, PdfViewerController ctrl) {
    // Se difiere un instante para no actualizar la pantalla a mitad de un dibujo.
    Future.microtask(() async {
      if (!mounted) return;
      setState(() {
        _document = document;
        _pageCount = ctrl.pageCount;
      });
      _reader.itemCount = ctrl.pageCount;
      _saveProgress();
      try {
        final outline = await document.loadOutline();
        if (mounted) setState(() => _outline = outline);
      } catch (_) {}
    });
  }

  void _onPageChanged(int? pageNumber) {
    if (pageNumber == null) return;
    Future.microtask(() {
      if (!mounted || pageNumber == _page) return;
      setState(() => _page = pageNumber);
      _saveProgress();
    });
  }

  bool _onTap(BuildContext context, PdfViewerController ctrl,
      PdfViewerGeneralTapHandlerDetails details) {
    if (details.type == PdfViewerGeneralTapType.tap) _toggleImmersive();
    return false;
  }

  void _saveProgress() {
    if (_pageCount <= 0) return;
    store.saveProgress(widget.doc.path, _page,
        _pageCount <= 1 ? 1.0 : (_page - 1) / (_pageCount - 1));
  }

  void _goToPage(int n) {
    if (!controller.isReady) return;
    controller.goToPage(pageNumber: n.clamp(1, math.max(1, _pageCount)).toInt());
  }

  /// La lectura en voz alta pasa de página sola.
  void _onReadPage(int index) {
    final page = index + 1;
    if (mounted && controller.isReady && page != _page) {
      controller.goToPage(pageNumber: page);
    }
  }

  Future<void> _listen() async {
    if (_pageCount <= 0) return;
    if (_reader.isActive) {
      _reader.togglePlay(_reader.item);
      return;
    }
    await askVoiceOnce(context);
    if (!mounted) return;
    _reader.playFrom(_page - 1);
  }

  void _toggleImmersive() {
    if (!mounted) return;
    setState(() => _immersive = !_immersive);
    SystemChrome.setEnabledSystemUIMode(
        _immersive ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge);
  }

  void _toggleHorizontal() {
    final page = _page;
    setState(() {
      _horizontal = !_horizontal;
      _viewer = _buildViewer();
    });
    settings.setPdfHorizontal(_horizontal);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !controller.isReady) return;
      controller.invalidate();
      Future<void>.delayed(const Duration(milliseconds: 200), () {
        if (mounted && controller.isReady) {
          controller.goToPage(pageNumber: page, duration: Duration.zero);
        }
      });
    });
  }

  void _toggleBookmark() {
    final added =
        notes.toggleBookmark(widget.doc.path, _page, 'Página $_page');
    showMessage(added
        ? 'Marcador en la página $_page.'
        : 'Marcador quitado de la página $_page.');
  }

  Future<void> _askPage() async {
    if (_pageCount <= 0) return;
    final input = TextEditingController();
    final result = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ir a la página'),
        content: TextField(
          controller: input,
          autofocus: true,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          decoration: InputDecoration(hintText: '1 – $_pageCount'),
          onSubmitted: (v) => Navigator.pop(ctx, int.tryParse(v)),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, int.tryParse(input.text)),
              child: const Text('Ir')),
        ],
      ),
    );
    if (result != null) _goToPage(result);
  }

  void _toggleSearch() {
    setState(() {
      _showSearch = !_showSearch;
      if (!_showSearch) {
        _searcher.resetTextSearch();
        _searchCtrl.clear();
      }
    });
  }

  // ---------- Índice, miniaturas, marcadores ----------

  void _showOutline() {
    final items = <(PdfOutlineNode, int)>[];
    void walk(List<PdfOutlineNode> nodes, int level) {
      for (final n in nodes) {
        items.add((n, level));
        walk(n.children, level + 1);
      }
    }

    walk(_outline, 0);
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
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final (node, level) = items[i];
            final page = node.dest?.pageNumber;
            return ListTile(
              contentPadding: EdgeInsets.only(left: 16.0 + level * 18, right: 16),
              title: Text(node.title, maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: page == null ? null : Text('$page'),
              onTap: () {
                Navigator.pop(ctx);
                final dest = node.dest;
                if (dest != null) controller.goToDest(dest);
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _showThumbnails() async {
    final doc = _document;
    if (doc == null) return;
    final page = await Navigator.of(context).push<int>(MaterialPageRoute<int>(
      builder: (_) => _ThumbnailsPage(document: doc, current: _page),
    ));
    if (page != null) _goToPage(page);
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (ctx) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (ctx, sc) => ListenableBuilder(
          listenable: notes,
          builder: (ctx, _) {
            final list = notes.bookmarksFor(widget.doc.path);
            if (list.isEmpty) {
              return ListView(
                controller: sc,
                padding: const EdgeInsets.all(24),
                children: const [
                  Text(
                    'Aún no tienes marcadores.\n\nToca el ícono de marcador '
                    'arriba para guardar la página actual.',
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
                  title: Text('Página ${b.position}'),
                  trailing: IconButton(
                    tooltip: 'Eliminar',
                    icon: const Icon(Icons.delete_outline_rounded),
                    onPressed: () =>
                        notes.removeBookmark(widget.doc.path, b.position),
                  ),
                  onTap: () {
                    Navigator.pop(ctx);
                    _goToPage(b.position);
                  },
                );
              },
            );
          },
        ),
      ),
    );
  }

  // ---------- Modo lectura (texto que se adapta a la pantalla) ----------

  Future<void> _openReflow() async {
    if (_pageCount <= 0) return;
    await _reader.stop();
    if (!mounted) return;
    final progress = ValueNotifier<double>(0);
    var cancelled = false;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Preparando modo lectura'),
        content: ValueListenableBuilder<double>(
          valueListenable: progress,
          builder: (ctx, v, _) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              LinearProgressIndicator(value: v == 0 ? null : v),
              const SizedBox(height: 12),
              Text('Sacando el texto de las páginas… ${(v * 100).round()}%'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => cancelled = true,
            child: const Text('Cancelar'),
          ),
        ],
      ),
    );

    ReflowDoc? result;
    Object? error;
    try {
      result = await buildReflowDoc(
        _text,
        onProgress: (done, total) =>
            progress.value = total == 0 ? 1.0 : done / total,
        isCancelled: () => cancelled,
      );
    } on ReflowCancelled {
      result = null;
    } catch (e) {
      error = e;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop(); // cierra el aviso

    final reflow = result;
    if (reflow == null) {
      if (error != null) showMessage('No se pudo preparar el modo lectura.');
      return;
    }
    if (reflow.doc.blocks.isEmpty) {
      showMessage('Este PDF no tiene texto (puede ser escaneado).');
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => TextReaderScreen(
        doc: widget.doc,
        reflow: reflow,
        startPage: _page,
      ),
    ));
    if (!mounted) return;
    // Vuelve a la página donde quedaste en el modo lectura.
    final p = store.progress[widget.doc.path]?.position;
    if (p != null && p != _page) _goToPage(p);
    if (settings.keepScreenOn) SystemBridge.keepScreenOn(true);
  }

  void _onMenu(String value) {
    switch (value) {
      case 'outline':
        _showOutline();
      case 'thumbs':
        _showThumbnails();
      case 'bookmarks':
        _showBookmarks();
      case 'reflow':
        _openReflow();
      case 'horizontal':
        _toggleHorizontal();
      case 'night':
        settings.setPdfNight(!settings.pdfNight);
      case 'fullscreen':
        _toggleImmersive();
      case 'voices':
        showVoicePicker(context);
      case 'settings':
        Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SettingsScreen()));
      case 'share':
        SharePlus.instance.share(ShareParams(files: [XFile(widget.doc.path)]));
    }
  }

  // ---------- Pantalla ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([settings, notes]),
      builder: (context, _) {
        final night = settings.pdfNight;
        final bookmarked = notes.hasBookmark(widget.doc.path, _page);
        return Scaffold(
          backgroundColor:
              night ? const Color(0xFF1B1B1B) : const Color(0xFFE4E4E4),
          appBar: _immersive
              ? null
              : AppBar(
                  title: Text(widget.doc.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  actions: [
                    IconButton(
                      tooltip: 'Escuchar',
                      icon: const Icon(Icons.headphones_rounded),
                      onPressed: _pageCount > 0 ? _listen : null,
                    ),
                    IconButton(
                      tooltip: 'Buscar texto',
                      icon: Icon(_showSearch ? Icons.search_off : Icons.search),
                      onPressed: _toggleSearch,
                    ),
                    IconButton(
                      tooltip: bookmarked ? 'Quitar marcador' : 'Marcar esta página',
                      icon: Icon(bookmarked
                          ? Icons.bookmark_rounded
                          : Icons.bookmark_border_rounded),
                      onPressed: _pageCount > 0 ? _toggleBookmark : null,
                    ),
                    PopupMenuButton<String>(
                      tooltip: 'Más',
                      onSelected: _onMenu,
                      itemBuilder: (_) => [
                        if (_outline.isNotEmpty)
                          const PopupMenuItem(
                            value: 'outline',
                            child: ListTile(
                              leading: Icon(Icons.toc_rounded),
                              title: Text('Índice'),
                            ),
                          ),
                        const PopupMenuItem(
                          value: 'thumbs',
                          child: ListTile(
                            leading: Icon(Icons.grid_view_rounded),
                            title: Text('Miniaturas'),
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
                          value: 'reflow',
                          child: ListTile(
                            leading: Icon(Icons.chrome_reader_mode_rounded),
                            title: Text('Modo lectura'),
                            subtitle: Text('Texto que se adapta a la pantalla'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'horizontal',
                          child: ListTile(
                            leading: Icon(_horizontal
                                ? Icons.swap_vert_rounded
                                : Icons.swap_horiz_rounded),
                            title: Text(_horizontal
                                ? 'Pasar páginas hacia abajo'
                                : 'Pasar páginas de lado'),
                          ),
                        ),
                        PopupMenuItem(
                          value: 'night',
                          child: ListTile(
                            leading: Icon(
                                night ? Icons.light_mode : Icons.dark_mode),
                            title: Text(night ? 'Modo día' : 'Modo noche'),
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'fullscreen',
                          child: ListTile(
                            leading: Icon(Icons.fullscreen_rounded),
                            title: Text('Pantalla completa'),
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
                          value: 'share',
                          child: ListTile(
                            leading: Icon(Icons.share_rounded),
                            title: Text('Compartir PDF'),
                          ),
                        ),
                      ],
                    ),
                  ],
                  bottom: _showSearch ? _searchBar() : null,
                ),
          body: SafeArea(
            top: _immersive,
            bottom: false,
            child: ColorFiltered(
              colorFilter: night ? _invertColors : _normalColors,
              child: _viewer,
            ),
          ),
          bottomNavigationBar: ListenableBuilder(
            listenable: _reader,
            builder: (context, _) {
              if (_reader.isActive) return ReadAloudBar(controller: _reader);
              if (_immersive || _pageCount <= 1) return const SizedBox.shrink();
              return _pageBar();
            },
          ),
        );
      },
    );
  }

  PreferredSizeWidget _searchBar() {
    final total = _searcher.matches.length;
    final current = _searcher.currentIndex;
    final Widget status;
    if (_searcher.isSearching) {
      status = const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2));
    } else if (_searchCtrl.text.isEmpty) {
      status = const SizedBox.shrink();
    } else {
      status = Text(total == 0 ? '0' : '${(current ?? 0) + 1}/$total');
    }
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
                textInputAction: TextInputAction.search,
                decoration: const InputDecoration(
                  hintText: 'Buscar en el PDF',
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
                onSubmitted: (t) {
                  final q = t.trim();
                  if (q.isEmpty) return;
                  _searcher.startTextSearch(q, caseInsensitive: true);
                },
              ),
            ),
            const SizedBox(width: 10),
            status,
            IconButton(
              tooltip: 'Anterior',
              icon: const Icon(Icons.keyboard_arrow_up),
              onPressed: total == 0 ? null : () => _searcher.goToPrevMatch(),
            ),
            IconButton(
              tooltip: 'Siguiente',
              icon: const Icon(Icons.keyboard_arrow_down),
              onPressed: total == 0 ? null : () => _searcher.goToNextMatch(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _pageBar() {
    final page = _page.clamp(1, _pageCount).toInt();
    final value = (_dragValue ?? page.toDouble())
        .clamp(1.0, _pageCount.toDouble())
        .toDouble();
    return Material(
      color: Theme.of(context).colorScheme.surface,
      elevation: 3,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 2, 8, 2),
          // Altura fija: sin ella el Slider se estira y tapa toda la pantalla.
          child: SizedBox(
            height: 52,
            child: Row(
            children: [
              Expanded(
                child: Slider(
                  value: value,
                  min: 1,
                  max: _pageCount.toDouble(),
                  label: '${value.round()}',
                  divisions: _pageCount - 1,
                  onChanged: (v) => setState(() => _dragValue = v),
                  onChangeEnd: (v) {
                    setState(() => _dragValue = null);
                    _goToPage(v.round());
                  },
                ),
              ),
              TextButton(
                onPressed: _askPage,
                child: Text('$page / $_pageCount'),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Cuadrícula con todas las páginas para saltar rápido.
class _ThumbnailsPage extends StatefulWidget {
  const _ThumbnailsPage({required this.document, required this.current});

  final PdfDocument document;
  final int current;

  @override
  State<_ThumbnailsPage> createState() => _ThumbnailsPageState();
}

class _ThumbnailsPageState extends State<_ThumbnailsPage> {
  ScrollController? _scroll;

  @override
  void dispose() {
    _scroll?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final count = widget.document.pages.length;
    return Scaffold(
      appBar: AppBar(title: Text('Páginas ($count)')),
      body: LayoutBuilder(
        builder: (context, box) {
          const cols = 3;
          const spacing = 10.0;
          const pad = 12.0;
          final w = (box.maxWidth - pad * 2 - spacing * (cols - 1)) / cols;
          final h = w / 0.7 + 24;
          final row = (widget.current - 1) ~/ cols;
          _scroll ??= ScrollController(
              initialScrollOffset: math.max(0.0, row * (h + spacing) - h));
          return GridView.builder(
            controller: _scroll,
            padding: const EdgeInsets.all(pad),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: cols,
              mainAxisSpacing: spacing,
              crossAxisSpacing: spacing,
              childAspectRatio: w / h,
            ),
            itemCount: count,
            itemBuilder: (context, i) {
              final selected = i + 1 == widget.current;
              return InkWell(
                onTap: () => Navigator.pop(context, i + 1),
                child: Column(
                  children: [
                    Expanded(
                      child: Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: selected ? primary : Colors.transparent,
                            width: 3,
                          ),
                        ),
                        child: PdfPageView(
                          document: widget.document,
                          pageNumber: i + 1,
                          maximumDpi: 72,
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${i + 1}',
                      style: TextStyle(
                        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                        color: selected ? primary : null,
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
