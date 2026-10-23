import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'exporter.dart';
import 'orientation.dart';
import 'rec_saver.dart';
import 'storage.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<File>? _files;
  String? _folder;
  final Set<String> _selected = {};

  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final files = await Storage.all();
    final folder = p.dirname((await Storage.photos()).path);
    if (mounted) {
      setState(() {
        _files = files;
        _folder = folder;
        _selected.removeWhere((s) => !files.any((f) => f.path == s));
      });
    }
  }

  Future<void> _open(File f) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => Storage.isPhoto(f.path)
          ? _PhotoView(file: f)
          : _VideoView(file: f),
    ));
    await _reload();
  }

  void _toggle(File f) {
    setState(() {
      if (!_selected.remove(f.path)) _selected.add(f.path);
    });
  }

  List<File> get _selectedFiles =>
      [for (final f in _files ?? const <File>[]) if (_selected.contains(f.path)) f];

  Future<void> _deleteSelected() async {
    final files = _selectedFiles;
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text('Apagar ${files.length} arquivo(s)?'),
        content: const Text('Eles serão apagados só deste app.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (ok != true) return;
    for (final f in files) {
      if (await f.exists()) await f.delete();
    }
    _selected.clear();
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: _selecting
          ? AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(_selected.clear),
              ),
              title: Text('${_selected.length} selecionado(s)'),
              actions: [
                IconButton(
                  tooltip: 'Selecionar tudo',
                  icon: const Icon(Icons.select_all),
                  onPressed: () => setState(() =>
                      _selected.addAll([for (final f in files ?? const <File>[]) f.path])),
                ),
                Builder(
                  builder: (ctx) => IconButton(
                    tooltip: 'Exportar',
                    icon: const Icon(Icons.ios_share),
                    onPressed: () => Exporter.openMenu(ctx, _selectedFiles),
                  ),
                ),
                IconButton(
                  tooltip: 'Apagar',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: _deleteSelected,
                ),
              ],
            )
          : AppBar(
              title: const Text('Galeria'),
              actions: [
                if (files != null && files.isNotEmpty)
                  TextButton.icon(
                    onPressed: () => setState(() => _selected.add(files.first.path)),
                    icon: const Icon(Icons.checklist),
                    label: const Text('Selecionar'),
                  ),
                if (Platform.isWindows && _folder != null)
                  IconButton(
                    tooltip: 'Abrir pasta',
                    icon: const Icon(Icons.folder_open),
                    onPressed: () => Process.run('explorer', [_folder!]),
                  ),
              ],
            ),
      body: files == null
          ? const Center(child: CircularProgressIndicator())
          : files.isEmpty
              ? const Center(child: Text('Nenhuma foto ou vídeo ainda.'))
              : Column(children: [
                  if (Platform.isWindows && _folder != null)
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: SelectableText('Pasta: $_folder',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  if (!_selecting)
                    const Padding(
                      padding: EdgeInsets.only(top: 4),
                      child: Text('Toque e segure para selecionar vários',
                          style: TextStyle(color: Colors.white38, fontSize: 12)),
                    ),
                  Expanded(
                    child: GridView.builder(
                      padding: const EdgeInsets.all(8),
                      gridDelegate:
                          const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 220,
                        mainAxisSpacing: 8,
                        crossAxisSpacing: 8,
                        childAspectRatio: 16 / 9,
                      ),
                      itemCount: files.length,
                      itemBuilder: (_, i) => _tile(files[i]),
                    ),
                  ),
                ]),
    );
  }

  Widget _tile(File f) {
    final photo = Storage.isPhoto(f.path);
    final sel = _selected.contains(f.path);
    return InkWell(
      onTap: () => _selecting ? _toggle(f) : _open(f),
      onLongPress: () => _toggle(f),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Stack(fit: StackFit.expand, children: [
          if (photo)
            Image.file(f, fit: BoxFit.cover, cacheWidth: 400)
          else
            Container(
              color: Colors.white10,
              child: const Icon(Icons.play_circle_outline, size: 40),
            ),
          if (sel) Container(color: Colors.greenAccent.withValues(alpha: 0.25)),
          if (_selecting)
            Positioned(
              top: 4,
              right: 4,
              child: Icon(
                sel ? Icons.check_circle : Icons.radio_button_unchecked,
                color: sel ? Colors.greenAccent : Colors.white70,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black54,
              padding: const EdgeInsets.all(4),
              child: Text(
                p.basename(f.path),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Ações comuns: converter, exportar e apagar.
List<Widget> _fileActions(BuildContext context, File file) {
  Future<void> delete() async {
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('Apagar?'),
        content: Text(p.basename(file.path)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: const Text('Cancelar')),
          FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: const Text('Apagar')),
        ],
      ),
    );
    if (ok == true) {
      if (await file.exists()) await file.delete();
      nav.pop();
    }
  }

  Future<void> convert() async {
    final messenger = ScaffoldMessenger.of(context);
    final nav = Navigator.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('Convertendo para vídeo… pode levar alguns segundos.'),
        duration: Duration(seconds: 30)));
    try {
      final out = await convertLocalDav(file);
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Vídeo criado: ${p.basename(out.path)}')));
      nav.pop();
    } catch (e) {
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Não deu para converter: $e')));
    }
  }

  return [
    if (file.path.toLowerCase().endsWith('.dav'))
      IconButton(
        tooltip: 'Converter para vídeo (.mkv)',
        icon: const Icon(Icons.transform),
        onPressed: convert,
      ),
    Builder(
      builder: (ctx) => IconButton(
        tooltip: 'Exportar / compartilhar',
        icon: const Icon(Icons.ios_share),
        onPressed: () => Exporter.openMenu(ctx, [file]),
      ),
    ),
    IconButton(
      tooltip: 'Apagar',
      icon: const Icon(Icons.delete_outline),
      onPressed: delete,
    ),
  ];
}

class _PhotoView extends StatelessWidget {
  const _PhotoView({required this.file});
  final File file;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(p.basename(file.path), style: const TextStyle(fontSize: 14)),
        actions: _fileActions(context, file),
      ),
      body: InteractiveViewer(
        maxScale: 6,
        child: Center(child: Image.file(file)),
      ),
    );
  }
}

class _VideoView extends StatefulWidget {
  const _VideoView({required this.file});
  final File file;

  @override
  State<_VideoView> createState() => _VideoViewState();
}

class _VideoViewState extends State<_VideoView> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  int _rotation = 0;
  bool _mirror = false;

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.file.path));
    CameraConfig.load().then((c) {
      if (mounted) {
        setState(() {
          _rotation = c.rotation;
          _mirror = c.mirror;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(p.basename(widget.file.path),
            style: const TextStyle(fontSize: 14)),
        actions: _fileActions(context, widget.file),
      ),
      body: Center(
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: orientVideo(Video(controller: _controller),
              rotation: _rotation, mirror: _mirror),
        ),
      ),
    );
  }
}
