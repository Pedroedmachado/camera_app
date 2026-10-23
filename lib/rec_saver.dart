import 'dart:io';

import 'package:gal/gal.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'converter.dart';
import 'dahua_http.dart';
import 'player_util.dart';
import 'sd_api.dart';
import 'storage.dart';

/// Nome do arquivo final: evento_20261023_101500.mkv (ou gravacao_...).
String recordingFileName(Recording rec, String ext) {
  final s = rec.start;
  final kind = rec.isMotion ? 'evento' : 'gravacao';
  return '${kind}_${s.year}${two(s.month)}${two(s.day)}_'
      '${two(s.hour)}${two(s.minute)}${two(s.second)}.$ext';
}

/// Baixa a gravação do cartão e converte para .mkv (vídeo comum).
/// No Android também coloca na galeria do celular (álbum CamLivre).
Future<File> saveRecordingAsVideo(
  SdApi api,
  Recording rec, {
  void Function(String status, double? progress)? onStatus,
  bool Function()? cancelled,
}) async {
  final dir = await Storage.videos();
  final out = File(p.join(dir.path, recordingFileName(rec, 'mkv')));
  if (await out.exists() && await out.length() > 20 * 1024) return out; // já salvo

  final tmp = await getTemporaryDirectory();
  final dav = File(p.join(tmp.path, 'camlivre_${DateTime.now().microsecondsSinceEpoch}.dav'));
  try {
    onStatus?.call('Baixando do cartão…', null);
    await api.download(rec, dav,
        cancelled: cancelled,
        onProgress: (r, t) => onStatus?.call('Baixando do cartão…', t > 0 ? r / t : null));
    if (cancelled?.call() == true) throw ConvertError('Cancelado.');
    try {
      await VideoConverter.davToMkv(dav, out,
          duration: rec.duration, onStatus: (s) => onStatus?.call(s, null));
    } catch (_) {
      final keep = File(p.join(dir.path, recordingFileName(rec, 'dav')));
      await dav.copy(keep.path);
      throw ConvertError(
          'Não consegui converter. O arquivo original (.dav) foi salvo na Galeria do app.');
    }
  } finally {
    if (await dav.exists()) await dav.delete();
  }

  if (Platform.isAndroid) {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putVideo(out.path, album: 'CamLivre');
    } catch (_) {
      // Fica pelo menos na Galeria do app.
    }
  }
  return out;
}

/// Converte um .dav que já está na Galeria do app.
Future<File> convertLocalDav(File dav, {void Function(String)? onStatus}) async {
  final out = File(p.setExtension(dav.path, '.mkv'));
  await VideoConverter.davToMkv(dav, out, onStatus: onStatus);
  if (Platform.isAndroid) {
    try {
      if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
      await Gal.putVideo(out.path, album: 'CamLivre');
    } catch (_) {}
  }
  return out;
}
