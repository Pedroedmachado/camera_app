import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'storage.dart';

/// Exportar fotos e vídeos: compartilhar, salvar como e salvar em pasta.
class Exporter {
  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 5)));
  }

  /// Abre a janela de compartilhar do sistema (WhatsApp, e-mail, Drive…).
  static Future<void> share(BuildContext context, List<File> files) async {
    if (files.isEmpty) return;
    final box = context.findRenderObject() as RenderBox?;
    try {
      await Share.shareXFiles(
        [for (final f in files) XFile(f.path)],
        subject: 'CamLivre',
        sharePositionOrigin:
            box == null ? null : box.localToGlobal(Offset.zero) & box.size,
      );
    } catch (e) {
      if (Platform.isWindows && files.length == 1) {
        // Plano B no PC: mostra o arquivo no Explorador.
        await Process.run('explorer', ['/select,', files.first.path]);
      } else if (context.mounted) {
        _snack(context, 'Não deu para compartilhar: $e');
      }
    }
  }

  /// Escolhe nome e local para salvar um arquivo.
  static Future<void> saveAs(BuildContext context, File file) async {
    final name = p.basename(file.path);
    try {
      String? dest;
      if (Platform.isAndroid || Platform.isIOS) {
        // No celular o sistema grava os bytes no local escolhido.
        dest = await FilePicker.platform.saveFile(
          dialogTitle: 'Salvar como',
          fileName: name,
          bytes: await file.readAsBytes(),
        );
        if (dest != null && context.mounted) _snack(context, 'Salvo: $name');
        return;
      }
      dest = await FilePicker.platform.saveFile(
        dialogTitle: 'Salvar como',
        fileName: name,
      );
      if (dest == null) return;
      if (p.extension(dest).isEmpty) dest = '$dest${p.extension(name)}';
      await file.copy(dest);
      if (context.mounted) _snack(context, 'Salvo em $dest');
    } catch (e) {
      if (context.mounted) _snack(context, 'Não deu para salvar: $e');
    }
  }

  /// Copia vários arquivos para uma pasta (PC, pendrive…).
  static Future<void> toFolder(BuildContext context, List<File> files) async {
    final dir = await FilePicker.platform.getDirectoryPath(
        dialogTitle: 'Escolha a pasta para exportar');
    if (dir == null) return;
    var ok = 0;
    final errors = <String>[];
    for (final f in files) {
      try {
        var dest = p.join(dir, p.basename(f.path));
        var n = 1;
        while (await File(dest).exists()) {
          dest = p.join(dir,
              '${p.basenameWithoutExtension(f.path)} ($n)${p.extension(f.path)}');
          n++;
        }
        await f.copy(dest);
        ok++;
      } catch (e) {
        errors.add('${p.basename(f.path)}: $e');
      }
    }
    if (!context.mounted) return;
    if (errors.isNotEmpty && ok == 0 && Platform.isAndroid) {
      _snack(context,
          'O Android não deixou gravar nessa pasta. Use “Compartilhar” ou “Galeria do celular”.');
      return;
    }
    _snack(context,
        '$ok arquivo(s) exportado(s) para $dir${errors.isEmpty ? '' : ' · ${errors.length} com erro'}');
  }

  /// Android: coloca na galeria do celular (álbum CamLivre).
  static Future<void> toPhoneGallery(BuildContext context, List<File> files) async {
    var ok = 0, skipped = 0;
    try {
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      for (final f in files) {
        if (f.path.toLowerCase().endsWith('.dav')) {
          skipped++;
          continue;
        }
        if (Storage.isPhoto(f.path)) {
          await Gal.putImage(f.path, album: 'CamLivre');
        } else {
          await Gal.putVideo(f.path, album: 'CamLivre');
        }
        ok++;
      }
    } catch (e) {
      if (context.mounted) _snack(context, 'Não deu para salvar: $e');
      return;
    }
    if (context.mounted) {
      _snack(context,
          '$ok salvo(s) na galeria do celular${skipped > 0 ? ' · $skipped .dav ignorado(s) (converta antes)' : ''}.');
    }
  }

  /// Menu com todas as opções de exportar.
  static Future<void> openMenu(BuildContext context, List<File> files) async {
    if (files.isEmpty) return;
    final single = files.length == 1;
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (c) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(single
                ? 'Exportar ${p.basename(files.first.path)}'
                : 'Exportar ${files.length} arquivos'),
          ),
          ListTile(
            leading: const Icon(Icons.share_outlined),
            title: const Text('Compartilhar'),
            subtitle: const Text('WhatsApp, e-mail, Drive…'),
            onTap: () => Navigator.pop(c, 'share'),
          ),
          if (single)
            ListTile(
              leading: const Icon(Icons.save_as_outlined),
              title: const Text('Salvar como…'),
              subtitle: const Text('Escolher nome e local'),
              onTap: () => Navigator.pop(c, 'saveas'),
            ),
          if (!single || !Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.drive_folder_upload_outlined),
              title: const Text('Exportar para uma pasta'),
              subtitle: const Text('PC, pendrive, cartão…'),
              onTap: () => Navigator.pop(c, 'folder'),
            ),
          if (Platform.isAndroid)
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeria do celular'),
              subtitle: const Text('Álbum CamLivre'),
              onTap: () => Navigator.pop(c, 'gallery'),
            ),
        ]),
      ),
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case 'share':
        await share(context, files);
      case 'saveas':
        await saveAs(context, files.first);
      case 'folder':
        await toFolder(context, files);
      case 'gallery':
        await toPhoneGallery(context, files);
    }
  }
}
