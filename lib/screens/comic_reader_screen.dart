import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../models.dart';
import '../services/comic_source.dart';
import '../services/library_store.dart';
import '../services/reader_settings.dart';
import '../services/system_bridge.dart';

/// Velocidad del autodesplazamiento (píxeles por segundo) para cada nivel.
const _autoSpeeds = <int>[0, 45, 90, 150, 230, 340];

/// Lector de manhua, manhwa, manga y cómics: tira vertical continua
/// (como en las apps de webtoon) o página por página.
class ComicReaderScreen extends StatefulWidget {
  const ComicReaderScreen({super.key, required this.doc});

  final DocItem doc;

  @override
  State<ComicReaderScreen> createState() => _ComicReaderScreenState();
}

class _ComicReaderScreenState extends State<ComicReaderScreen> {
  final store = LibraryStore.instance;
  final settings = ReaderSettings.instance;
  final _items = ItemScrollController();
  final _positions = ItemPositionsListener.create();
  final _offset = ScrollOffsetController();
  final _zoom = TransformationController();

  PageController? _pager;
  List<String>? _pages;
  Object? _error;
  int _page = 0;
  double? _drag;
  bool _ui = true;
  bool _zoomed = false;
  Timer? _auto;
  Offset? _doubleTapAt;
  DocItem? _prev;
  DocItem? _next;

  int get _count => _pages?.length ?? 0;

  @override
  void initState() {
    super.initState();
    _page = store.progress[widget.doc.path]?.position ?? 0;
    _positions.itemPositions.addListener(_onPositions);
    SystemBridge.keepScreenOn(true);
    _findChapters();
    _load();
  }

  @override
  void dispose() {
    _stopAuto();
    _positions.itemPositions.removeListener(_onPositions);
    _pager?.dispose();
    _zoom.dispose();
    store.flush();
    if (!settings.keepScreenOn) SystemBridge.keepScreenOn(false);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final pages = await loadComicPages(widget.doc);
      if (!mounted) return;
      if (pages.isEmpty) throw const FormatException('No encontramos imágenes en este archivo.');
      setState(() {
        _pages = pages;
        _page = _page.clamp(0, pages.length - 1).toInt();
        _pager = PageController(initialPage: _page);
      });
      _save();
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  /// Capítulo anterior y siguiente: los demás manhua de la misma carpeta.
  void _findChapters() {
    final dir = p.dirname(widget.doc.path);
    final list = store.docs
        .where((d) => d.type == DocType.comic && p.dirname(d.path) == dir)
        .toList()
      ..sort((a, b) => naturalCompare(a.name, b.name));
    final i = list.indexWhere((d) => d.path == widget.doc.path);
    if (i < 0) return;
    _prev = i > 0 ? list[i - 1] : null;
    _next = i + 1 < list.length ? list[i + 1] : null;
  }

  void _save() {
    final n = _count;
    if (n == 0) return;
    final i = _page.clamp(0, n - 1).toInt();
    store.saveProgress(widget.doc.path, i, n <= 1 ? 1.0 : i / (n - 1));
  }

  void _setPage(int i) {
    if (i == _page || i < 0 || i >= _count) return;
    setState(() => _page = i);
    _save();
  }

  /// En la tira vertical, la página actual es la que ocupa el centro.
  void _onPositions() {
    if (settings.comicPaged || _count == 0) return;
    final positions = _positions.itemPositions.value;
    int? current;
    for (final pos in positions) {
      if (pos.index >= _count) continue;
      if (pos.itemLeadingEdge <= 0.5 && pos.itemTrailingEdge > 0.5) {
        current = pos.index;
        break;
      }
    }
    if (current == null) return;
    _setPage(current);
    // Al llegar al final se detiene el autodesplazamiento.
    if (_auto != null && positions.any((pos) => pos.index == _count && pos.itemLeadingEdge < 0.9)) {
      _stopAuto();
    }
  }

  void _jump(int i) {
    final target = i.clamp(0, math.max(0, _count - 1)).toInt();
    if (settings.comicPaged) {
      _pager?.jumpToPage(target);
    } else if (_items.isAttached) {
      _items.jumpTo(index: target);
    }
    _setPage(target);
  }

  void _turn(int delta) {
    final pager = _pager;
    if (pager == null || !pager.hasClients) return;
    final target = (pager.page?.round() ?? _page) + delta;
    if (target < 0 || target > _count) return;
    pager.animateToPage(target,
        duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
  }

  void _toggleUi() {
    setState(() => _ui = !_ui);
    SystemChrome.setEnabledSystemUIMode(
        _ui ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky);
  }

  // ---------- Autodesplazamiento (tira vertical) ----------

  void _toggleAuto() {
    if (_auto != null) {
      _stopAuto();
    } else {
      _startAuto();
    }
  }

  void _startAuto() {
    if (settings.comicPaged) return;
    _auto?.cancel();
    _auto = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      final speed = _autoSpeeds[settings.comicAutoSpeed];
      _offset.animateScroll(
        offset: speed / 10,
        duration: const Duration(milliseconds: 100),
      );
    });
    if (_ui) _toggleUi();
    setState(() {});
  }

  void _stopAuto() {
    if (_auto == null) return;
    _auto?.cancel();
    _auto = null;
    if (mounted) setState(() {});
  }

  // ---------- Zoom con doble toque (tira vertical) ----------

  void _onDoubleTap() {
    if (_zoomed) {
      _zoom.value = Matrix4.identity();
      setState(() => _zoomed = false);
      return;
    }
    final at = _doubleTapAt ?? Offset.zero;
    const s = 2.0;
    _zoom.value = Matrix4.diagonal3Values(s, s, 1)
      ..setTranslationRaw(at.dx * (1 - s), at.dy * (1 - s), 0);
    setState(() => _zoomed = true);
  }

  /// Cambia entre tira vertical y por páginas sin perder la página actual.
  void _setMode(bool paged) {
    if (paged == settings.comicPaged) return;
    _stopAuto();
    final old = _pager;
    _pager = PageController(initialPage: _page);
    settings.setComicPaged(paged);
    // El controlador viejo se libera cuando la vista anterior ya no existe.
    WidgetsBinding.instance.addPostFrameCallback((_) => old?.dispose());
  }

  void _openChapter(DocItem? doc) {
    if (doc == null) return;
    _stopAuto();
    if (_count > 0) {
      store.saveProgress(widget.doc.path, _count - 1, 1.0);
    }
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => ComicReaderScreen(doc: doc),
    ));
  }

  // ---------- Pantalla ----------

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) {
        final bg = settings.comicWhiteBg ? Colors.white : Colors.black;
        final fg = settings.comicWhiteBg ? Colors.black87 : Colors.white;
        return Scaffold(
          backgroundColor: bg,
          body: Stack(
            children: [
              Positioned.fill(child: _content(bg, fg)),
              if (_ui) _topBar(),
              if (_ui && _count > 0) _bottomBar(),
            ],
          ),
        );
      },
    );
  }

  Widget _content(Color bg, Color fg) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(
            'No se pudo abrir este manhua.\n\n$_error',
            textAlign: TextAlign.center,
            style: TextStyle(color: fg),
          ),
        ),
      );
    }
    final pages = _pages;
    if (pages == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text('Preparando el capítulo…', style: TextStyle(color: fg)),
          ],
        ),
      );
    }
    return settings.comicPaged ? _paged(pages, fg) : _strip(pages, fg);
  }

  /// Tira vertical continua, sin espacios entre imágenes (manhua/webtoon).
  Widget _strip(List<String> pages, Color fg) {
    final screen = MediaQuery.of(context).size;
    return Listener(
      onPointerDown: (_) => _stopAuto(),
      child: GestureDetector(
        onTap: _toggleUi,
        onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
        onDoubleTap: _onDoubleTap,
        child: InteractiveViewer(
          transformationController: _zoom,
          minScale: 1,
          maxScale: 4,
          panEnabled: _zoomed,
          onInteractionEnd: (_) {
            final z = _zoom.value.getMaxScaleOnAxis() > 1.01;
            if (z != _zoomed) setState(() => _zoomed = z);
          },
          child: ScrollablePositionedList.builder(
            itemCount: pages.length + 1,
            initialScrollIndex: _page.clamp(0, pages.length - 1).toInt(),
            itemScrollController: _items,
            itemPositionsListener: _positions,
            scrollOffsetController: _offset,
            minCacheExtent: screen.height * 2,
            itemBuilder: (context, i) => i == pages.length
                ? _endOfChapter(fg)
                : _image(pages[i], i, strip: true),
          ),
        ),
      ),
    );
  }

  /// Una página a la vez, deslizando de lado (manga, cómic).
  Widget _paged(List<String> pages, Color fg) {
    return LayoutBuilder(
      builder: (context, box) => GestureDetector(
        onTapUp: (d) {
          final x = d.localPosition.dx;
          final rtl = settings.comicRtl;
          if (x < box.maxWidth * 0.3) {
            _turn(rtl ? 1 : -1);
          } else if (x > box.maxWidth * 0.7) {
            _turn(rtl ? -1 : 1);
          } else {
            _toggleUi();
          }
        },
        child: PageView.builder(
          controller: _pager,
          reverse: settings.comicRtl,
          itemCount: pages.length + 1,
          onPageChanged: (i) {
            if (i < pages.length) _setPage(i);
          },
          itemBuilder: (context, i) => i == pages.length
              ? Center(child: _endOfChapter(fg))
              : InteractiveViewer(
                  minScale: 1,
                  maxScale: 4,
                  child: Center(child: _image(pages[i], i, strip: false)),
                ),
        ),
      ),
    );
  }

  Widget _image(String path, int index, {required bool strip}) {
    final mq = MediaQuery.of(context);
    final widthPx = (mq.size.width * mq.devicePixelRatio).round();
    // Se limita el tamaño para que las tiras muy largas no agoten la memoria.
    final provider = ResizeImage(
      FileImage(File(path)),
      width: widthPx,
      height: 8192,
      policy: ResizeImagePolicy.fit,
    );
    return Image(
      image: provider,
      width: strip ? double.infinity : null,
      fit: strip ? BoxFit.fitWidth : BoxFit.contain,
      filterQuality: FilterQuality.medium,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, sync) {
        if (frame != null || sync) return child;
        return SizedBox(
          height: strip ? mq.size.height * 0.7 : null,
          child: const Center(
            child: SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        );
      },
      errorBuilder: (context, error, stack) => SizedBox(
        height: 220,
        child: Center(
          child: Text(
            'No se pudo mostrar la página ${index + 1}',
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      ),
    );
  }

  Widget _endOfChapter(Color fg) {
    final next = _next;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 120),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle_outline_rounded, color: fg, size: 40),
          const SizedBox(height: 12),
          Text('Fin de "${widget.doc.name}"',
              textAlign: TextAlign.center,
              style: TextStyle(color: fg, fontSize: 18, fontWeight: FontWeight.w600)),
          const SizedBox(height: 20),
          if (next != null)
            FilledButton.icon(
              icon: const Icon(Icons.skip_next_rounded),
              label: Text('Siguiente: ${next.name}',
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onPressed: () => _openChapter(next),
            )
          else
            Text('No hay más capítulos en esta carpeta.',
                textAlign: TextAlign.center,
                style: TextStyle(color: fg.withValues(alpha: 0.7))),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Text('Volver a la biblioteca'),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return Positioned(
      left: 0,
      right: 0,
      top: 0,
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: SafeArea(
          bottom: false,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Volver',
                  color: Colors.white,
                  icon: const Icon(Icons.arrow_back_rounded),
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(widget.doc.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Colors.white, fontWeight: FontWeight.w600)),
                      Text(
                        widget.doc.isFolder || p.extension(widget.doc.path).isEmpty
                            ? widget.doc.folder
                            : '${widget.doc.folder} · ${p.extension(widget.doc.path).substring(1).toUpperCase()}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: settings.comicPaged ? 'Tira vertical' : 'Por páginas',
                  color: Colors.white,
                  icon: Icon(settings.comicPaged
                      ? Icons.view_day_rounded
                      : Icons.auto_stories_rounded),
                  onPressed: () => _setMode(!settings.comicPaged),
                ),
                IconButton(
                  tooltip: 'Opciones de lectura',
                  color: Colors.white,
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: _showOptions,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final n = _count;
    final value = (_drag ?? _page.toDouble()).clamp(0.0, math.max(0, n - 1).toDouble()).toDouble();
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Material(
        color: Colors.black.withValues(alpha: 0.72),
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 60,
            child: Row(
              children: [
                IconButton(
                  tooltip: 'Capítulo anterior',
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  icon: const Icon(Icons.skip_previous_rounded),
                  onPressed: _prev == null ? null : () => _openChapter(_prev),
                ),
                if (!settings.comicPaged)
                  IconButton(
                    tooltip: _auto == null ? 'Desplazar solo' : 'Detener',
                    color: Colors.white,
                    icon: Icon(_auto == null
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded),
                    onPressed: _toggleAuto,
                  ),
                Expanded(
                  child: n > 1
                      ? SizedBox(
                          height: 48,
                          child: Slider(
                            value: value,
                            min: 0,
                            max: (n - 1).toDouble(),
                            divisions: n - 1,
                            label: '${value.round() + 1}',
                            onChanged: (v) => setState(() => _drag = v),
                            onChangeEnd: (v) {
                              setState(() => _drag = null);
                              _jump(v.round());
                            },
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Text('${value.round() + 1} / $n',
                    style: const TextStyle(color: Colors.white)),
                IconButton(
                  tooltip: 'Capítulo siguiente',
                  color: Colors.white,
                  disabledColor: Colors.white24,
                  icon: const Icon(Icons.skip_next_rounded),
                  onPressed: _next == null ? null : () => _openChapter(_next),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showOptions() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => ListenableBuilder(
        listenable: settings,
        builder: (ctx, _) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Modo de lectura'),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(
                          value: false,
                          icon: Icon(Icons.view_day_rounded),
                          label: Text('Tira vertical')),
                      ButtonSegment(
                          value: true,
                          icon: Icon(Icons.auto_stories_rounded),
                          label: Text('Por páginas')),
                    ],
                    selected: {settings.comicPaged},
                    onSelectionChanged: (s) => _setMode(s.first),
                  ),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Derecha a izquierda (manga japonés)'),
                  subtitle: const Text('Solo en modo por páginas'),
                  value: settings.comicRtl,
                  onChanged: settings.setComicRtl,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Fondo blanco'),
                  value: settings.comicWhiteBg,
                  onChanged: settings.setComicWhiteBg,
                ),
                Text('Velocidad al desplazar solo: ${settings.comicAutoSpeed}'),
                Slider(
                  value: settings.comicAutoSpeed.toDouble(),
                  min: 1,
                  max: 5,
                  divisions: 4,
                  label: '${settings.comicAutoSpeed}',
                  onChanged: (v) => settings.setComicAutoSpeed(v.round()),
                ),
                const Text(
                  'Consejos: toca la imagen para mostrar u ocultar los controles. '
                  'Doble toque para acercar. En modo por páginas, toca los bordes '
                  'para pasar de página.',
                  style: TextStyle(fontSize: 13),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
