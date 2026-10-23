import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'storage.dart';

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> {
  List<File>? _files;
  String? _folder;

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

  @override
  Widget build(BuildContext context) {
    final files = _files;
    return Scaffold(
      appBar: AppBar(title: const Text('Galeria')),
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
    return InkWell(
      onTap: () => _open(f),
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

/// Ações comuns: mandar para a galeria do Android e apagar.
List<Widget> _fileActions(BuildContext context, File file) {
  Future<void> toPhoneGallery() async {
    final messenger = ScaffoldMessenger.of(context);
    if (file.path.toLowerCase().endsWith('.dav')) {
      messenger.showSnackBar(const SnackBar(
          content: Text(
              'Arquivo .dav (original da câmera) não entra na galeria do celular. '
              'Assista aqui no app ou use “Gravar” na reprodução para gerar um .mkv.')));
      return;
    }
    try {
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      if (Storage.isPhoto(file.path)) {
        await Gal.putImage(file.path, album: 'CamLivre');
      } else {
        await Gal.putVideo(file.path, album: 'CamLivre');
      }
      messenger.showSnackBar(
          const SnackBar(content: Text('Salvo na galeria do celular.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Não deu para salvar: $e')));
    }
  }

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

  return [
    if (Platform.isAndroid)
      IconButton(
        tooltip: 'Salvar na galeria do celular',
        icon: const Icon(Icons.download_outlined),
        onPressed: toPhoneGallery,
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

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.file.path));
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
          child: Video(controller: _controller),
        ),
      ),
    );
  }
}
