import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Pastas onde o app guarda fotos e vídeos.
/// Android: pasta do app (dá para mandar para a galeria pela tela Galeria).
/// Windows: Documentos\CamLivre.
class Storage {
  static Future<Directory> _base() async {
    Directory base;
    if (Platform.isAndroid) {
      base = (await getExternalStorageDirectory()) ??
          await getApplicationDocumentsDirectory();
    } else {
      final docs = await getApplicationDocumentsDirectory();
      base = Directory(p.join(docs.path, 'CamLivre'));
    }
    if (!await base.exists()) await base.create(recursive: true);
    return base;
  }

  static Future<Directory> _sub(String name) async {
    final d = Directory(p.join((await _base()).path, name));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  static Future<Directory> photos() => _sub('Fotos');
  static Future<Directory> videos() => _sub('Videos');

  static String stamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  static bool isPhoto(String path) {
    final e = p.extension(path).toLowerCase();
    return e == '.jpg' || e == '.jpeg' || e == '.png';
  }

  static bool isVideo(String path) {
    final e = p.extension(path).toLowerCase();
    return e == '.mkv' || e == '.mp4' || e == '.ts' || e == '.dav';
  }

  /// Todos os arquivos (fotos + vídeos), mais recentes primeiro.
  static Future<List<File>> all() async {
    final files = <File>[];
    for (final d in [await photos(), await videos()]) {
      await for (final e in d.list()) {
        if (e is File && (isPhoto(e.path) || isVideo(e.path))) files.add(e);
      }
    }
    files.sort((a, b) => b.statSync().modified.compareTo(a.statSync().modified));
    return files;
  }
}
