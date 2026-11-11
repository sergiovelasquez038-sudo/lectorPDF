import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:pdfrx/pdfrx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';

import '../models.dart';
import '../navigation.dart' as nav;
import '../services/comic_source.dart';
import '../services/extractors.dart';
import '../services/library_store.dart';
import '../services/tts_service.dart';
import '../widgets/voice_picker_sheet.dart';
import 'settings_screen.dart';

enum LibFilter {
  all('Todos'),
  favorites('Favoritos'),
  pdf('PDF'),
  epub('EPUB'),
  docx('Word'),
  txt('Texto'),
  comic('Manhua');

  const LibFilter(this.label);
  final String label;

  bool matches(DocItem d, LibraryStore store) => switch (this) {
        LibFilter.all => true,
        LibFilter.favorites => store.isFavorite(d.path),
        LibFilter.pdf => d.type == DocType.pdf,
        LibFilter.epub => d.type == DocType.epub,
        LibFilter.docx => d.type == DocType.docx,
        LibFilter.txt => d.type == DocType.txt,
        LibFilter.comic => d.type == DocType.comic,
      };
}

/// Abre el lector adecuado según el formato.
void _openDoc(BuildContext context, DocItem doc) => nav.openDocument(doc);

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key});

  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final store = LibraryStore.instance;
  final _searchCtrl = TextEditingController();
  late final AppLifecycleListener _lifecycle;

  bool _searching = false;
  String _query = '';
  LibFilter _filter = LibFilter.all;
  SortMode _sort = SortMode.recent;

  @override
  void initState() {
    super.initState();
    // Si el usuario dio el permiso desde Ajustes, lo detectamos al volver.
    _lifecycle = AppLifecycleListener(onResume: store.recheckPermission);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  List<DocItem> _visibleDocs() {
    final q = foldText(_query.trim());
    final list = store.docs.where((d) {
      if (!_filter.matches(d, store)) return false;
      return q.isEmpty || foldText(d.name).contains(q);
    }).toList();
    switch (_sort) {
      case SortMode.recent:
        list.sort((a, b) => b.modifiedMs.compareTo(a.modifiedMs));
      case SortMode.name:
        list.sort((a, b) => foldText(a.name).compareTo(foldText(b.name)));
      case SortMode.size:
        list.sort((a, b) => b.size.compareTo(a.size));
    }
    return list;
  }

  Future<void> _askPermission() async {
    final ok = await store.requestPermission();
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
              'Sin el permiso no podemos buscar tus documentos.'),
          action: SnackBarAction(label: 'Ajustes', onPressed: openAppSettings),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, TtsService.instance]),
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: _searching
                ? TextField(
                    controller: _searchCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Buscar por nombre…',
                      border: InputBorder.none,
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  )
                : const Text('Mis documentos'),
            actions: [
              IconButton(
                tooltip: _searching ? 'Cerrar búsqueda' : 'Buscar',
                icon: Icon(_searching ? Icons.close : Icons.search),
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) {
                    _query = '';
                    _searchCtrl.clear();
                  }
                }),
              ),
              PopupMenuButton<SortMode>(
                tooltip: 'Ordenar',
                icon: const Icon(Icons.sort),
                initialValue: _sort,
                onSelected: (s) => setState(() => _sort = s),
                itemBuilder: (_) => [
                  for (final s in SortMode.values)
                    PopupMenuItem(value: s, child: Text(s.label)),
                ],
              ),
              IconButton(
                tooltip: 'Configuración (voces, letra, temas)',
                icon: const Icon(Icons.settings_rounded),
                onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
              ),
            ],
            bottom: store.scanning
                ? const PreferredSize(
                    preferredSize: Size.fromHeight(3),
                    child: LinearProgressIndicator(minHeight: 3),
                  )
                : null,
          ),
          body: store.hasPermission
              ? _buildLibrary(context)
              : _PermissionView(onPressed: _askPermission),
        );
      },
    );
  }

  Widget _buildLibrary(BuildContext context) {
    final items = _visibleDocs();
    final recent = store.recent;
    final showRecent =
        recent.isNotEmpty && _query.isEmpty && _filter == LibFilter.all;
    final textTheme = Theme.of(context).textTheme;

    return RefreshIndicator(
      onRefresh: store.scan,
      child: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverToBoxAdapter(child: _filterChips()),
          if (!TtsService.instance.hasChosenVoice &&
              !TtsService.instance.voicePrompted)
            const SliverToBoxAdapter(child: _VoiceBanner()),
          if (showRecent) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text('Continuar leyendo', style: textTheme.titleMedium),
              ),
            ),
            SliverToBoxAdapter(
              child: SizedBox(
                height: 176,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: recent.length,
                  itemBuilder: (context, i) => _RecentCard(doc: recent[i]),
                ),
              ),
            ),
          ],
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Text(
                store.scanning && store.docs.isEmpty
                    ? 'Buscando documentos en tu teléfono…'
                    : '${items.length} documento${items.length == 1 ? '' : 's'}',
                style: textTheme.titleSmall,
              ),
            ),
          ),
          if (items.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyView(
                scanning: store.scanning,
                filtered: _query.isNotEmpty || _filter != LibFilter.all,
              ),
            )
          else
            SliverList.builder(
              itemCount: items.length,
              itemBuilder: (context, i) => _DocTile(doc: items[i]),
            ),
          const SliverToBoxAdapter(child: SizedBox(height: 24)),
        ],
      ),
    );
  }

  Widget _filterChips() {
    int count(LibFilter f) => store.docs.where((d) => f.matches(d, store)).length;
    return SizedBox(
      height: 52,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        children: [
          for (final f in LibFilter.values)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: ChoiceChip(
                label: Text('${f.label} · ${count(f)}'),
                selected: _filter == f,
                onSelected: (_) => setState(() => _filter = f),
              ),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _TypeBadge extends StatelessWidget {
  const _TypeBadge({required this.type, this.width = 44, this.height = 56});

  final DocType type;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final color = Color(type.colorValue);
    return Container(
      width: width,
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        type == DocType.docx ? 'DOC' : type.label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.w800,
          fontSize: width * (type == DocType.comic ? 0.18 : 0.24),
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({required this.doc});

  final DocItem doc;

  @override
  Widget build(BuildContext context) {
    final store = LibraryStore.instance;
    final prog = store.progress[doc.path];
    final fav = store.isFavorite(doc.path);
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;

    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      leading: _TypeBadge(type: doc.type),
      title: Text(doc.name, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${doc.folder} · ${doc.sizeLabel} · ${formatDate(doc.modified)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: muted),
          ),
          if (prog != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: prog.fraction,
                        minHeight: 4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text('${(prog.fraction * 100).round()}%',
                      style: TextStyle(color: muted, fontSize: 12)),
                ],
              ),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: fav ? 'Quitar de favoritos' : 'Agregar a favoritos',
        icon: Icon(fav ? Icons.star_rounded : Icons.star_outline_rounded),
        color: fav ? Colors.amber.shade700 : null,
        onPressed: () => store.toggleFavorite(doc.path),
      ),
      onTap: () => _openDoc(context, doc),
      onLongPress: () => _showInfo(context, doc),
    );
  }
}

void _showInfo(BuildContext context, DocItem doc) {
  final store = LibraryStore.instance;
  showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(doc.name, style: Theme.of(ctx).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text('${doc.type.label} · ${doc.sizeLabel} · '
                'modificado ${formatDate(doc.modified)}'),
            const SizedBox(height: 8),
            SelectableText(doc.path,
                style: Theme.of(ctx).textTheme.bodySmall),
            const SizedBox(height: 16),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  icon: const Icon(Icons.menu_book_rounded),
                  label: const Text('Abrir'),
                  onPressed: () {
                    Navigator.pop(ctx);
                    _openDoc(context, doc);
                  },
                ),
                OutlinedButton.icon(
                  icon: Icon(store.isFavorite(doc.path)
                      ? Icons.star_rounded
                      : Icons.star_outline_rounded),
                  label: Text(store.isFavorite(doc.path)
                      ? 'Quitar favorito'
                      : 'Favorito'),
                  onPressed: () {
                    store.toggleFavorite(doc.path);
                    Navigator.pop(ctx);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (!doc.isFolder)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.share_rounded),
                title: const Text('Compartir'),
                onTap: () {
                  Navigator.pop(ctx);
                  SharePlus.instance.share(ShareParams(files: [XFile(doc.path)]));
                },
              ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.drive_file_rename_outline_rounded),
              title: const Text('Cambiar nombre'),
              onTap: () {
                Navigator.pop(ctx);
                _rename(context, doc);
              },
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline_rounded,
                  color: Theme.of(ctx).colorScheme.error),
              title: Text('Eliminar del teléfono',
                  style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              onTap: () {
                Navigator.pop(ctx);
                _delete(context, doc);
              },
            ),
          ],
        ),
      ),
    ),
  );
}

Future<void> _rename(BuildContext context, DocItem doc) async {
  final ctrl = TextEditingController(text: doc.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Cambiar nombre'),
      content: TextField(
        controller: ctrl,
        autofocus: true,
        decoration: InputDecoration(
          suffixText: p.extension(doc.path),
          border: const OutlineInputBorder(),
        ),
        onSubmitted: (v) => Navigator.pop(ctx, v),
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
  if (name == null) return;
  final error = await LibraryStore.instance.renameDoc(doc, name);
  nav.showMessage(error ?? 'Nombre cambiado.');
}

Future<void> _delete(BuildContext context, DocItem doc) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('¿Eliminar archivo?'),
      content: Text('"${doc.name}" se borrará del teléfono. '
          'Esta acción no se puede deshacer.'),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Cancelar'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError),
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Eliminar'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  final error = await LibraryStore.instance.deleteDoc(doc);
  nav.showMessage(error ?? 'Archivo eliminado.');
}

/// Portada del documento: primera página del PDF o imagen del EPUB.
class _DocCover extends StatelessWidget {
  const _DocCover({required this.doc});

  final DocItem doc;

  static final Map<String, Future<Uint8List?>> _epubCovers = {};
  static final Map<String, Future<Uint8List?>> _comicCovers = {};

  Widget _fallback(Color color) => Container(
        color: color.withValues(alpha: 0.12),
        alignment: Alignment.center,
        child: Icon(
          doc.type == DocType.pdf
              ? Icons.picture_as_pdf_rounded
              : doc.type == DocType.epub
                  ? Icons.auto_stories_rounded
                  : doc.type == DocType.docx
                      ? Icons.description_rounded
                      : doc.type == DocType.comic
                          ? Icons.collections_bookmark_rounded
                          : Icons.notes_rounded,
          color: color,
          size: 40,
        ),
      );

  @override
  Widget build(BuildContext context) {
    final color = Color(doc.type.colorValue);
    switch (doc.type) {
      case DocType.pdf:
        return Container(
          color: Colors.white,
          child: PdfDocumentViewBuilder.file(
            doc.path,
            builder: (context, document) => document == null
                ? _fallback(color)
                : PdfPageView(
                    document: document,
                    pageNumber: 1,
                    maximumDpi: 60,
                    alignment: Alignment.topCenter,
                  ),
            errorBuilder: (context, error, stack) => _fallback(color),
          ),
        );
      case DocType.epub:
        final future =
            _epubCovers.putIfAbsent(doc.path, () => loadEpubCover(doc.path));
        return FutureBuilder<Uint8List?>(
          future: future,
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) return _fallback(color);
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              cacheWidth: 300,
              errorBuilder: (context, error, stack) => _fallback(color),
            );
          },
        );
      case DocType.comic:
        final future =
            _comicCovers.putIfAbsent(doc.path, () => loadComicCover(doc));
        return FutureBuilder<Uint8List?>(
          future: future,
          builder: (context, snap) {
            final bytes = snap.data;
            if (bytes == null) return _fallback(color);
            return Image.memory(
              bytes,
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
              cacheWidth: 300,
              errorBuilder: (context, error, stack) => _fallback(color),
            );
          },
        );
      case DocType.docx:
      case DocType.txt:
        return _fallback(color);
    }
  }
}

class _RecentCard extends StatelessWidget {
  const _RecentCard({required this.doc});

  final DocItem doc;

  @override
  Widget build(BuildContext context) {
    final prog = LibraryStore.instance.progress[doc.path];
    final color = Color(doc.type.colorValue);
    return SizedBox(
      width: 124,
      child: Card(
        clipBehavior: Clip.antiAlias,
        margin: const EdgeInsets.only(right: 12, bottom: 4),
        child: InkWell(
          onTap: () => _openDoc(context, doc),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: _DocCover(doc: doc)),
              if (prog != null)
                LinearProgressIndicator(
                  value: prog.fraction,
                  minHeight: 3,
                  color: color,
                  backgroundColor: color.withValues(alpha: 0.2),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 10),
                child: Text(
                  doc.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PermissionView extends StatelessWidget {
  const _PermissionView({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final t = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_rounded,
                size: 72, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 20),
            Text('Encuentra todos tus documentos',
                style: t.headlineSmall, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            Text(
              'Para buscar PDF, EPUB, Word y TXT en todo tu teléfono, '
              'Android pide el permiso "Acceso a todos los archivos". '
              'Tus archivos nunca salen del teléfono.',
              style: t.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              icon: const Icon(Icons.search_rounded),
              label: const Text('Dar permiso y buscar'),
              onPressed: onPressed,
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.scanning, required this.filtered});

  final bool scanning;
  final bool filtered;

  @override
  Widget build(BuildContext context) {
    final text = scanning
        ? 'Revisando carpetas…'
        : filtered
            ? 'No hay documentos que coincidan.'
            : 'No encontramos documentos.\nDesliza hacia abajo para buscar de nuevo.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              scanning ? Icons.manage_search_rounded : Icons.inbox_rounded,
              size: 56,
              color: Theme.of(context).colorScheme.outline,
            ),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}

/// Aviso para elegir la voz la primera vez.
class _VoiceBanner extends StatelessWidget {
  const _VoiceBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      color: scheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.record_voice_over_rounded, color: scheme.onPrimaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Elige la voz que te va a leer tus documentos',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => TtsService.instance.markVoicePrompted(),
                  child: const Text('Ahora no'),
                ),
                FilledButton(
                  onPressed: () async {
                    await TtsService.instance.markVoicePrompted();
                    if (context.mounted) await showVoicePicker(context);
                  },
                  child: const Text('Elegir voz'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
