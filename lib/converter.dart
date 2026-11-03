import 'dart:async';
import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import 'media/dav_reader.dart';
import 'player_util.dart';

class ConvertError implements Exception {
  final String message;
  ConvertError(this.message);
  @override
  String toString() => message;
}

/// Converte gravações (.dav da câmera ou .mkv) em MP4, que abre em qualquer
/// celular, PC, VLC e WhatsApp. Não recodifica o vídeo: sem perda de qualidade.
class VideoConverter {
  static Future<File> toMp4(
    File input,
    File out, {
    Duration? duration,
    DateTime? from,
    DateTime? to,
    void Function(String status)? onStatus,
  }) async {
    if (input.path.toLowerCase().endsWith('.dav')) {
      // Conversão própria do app (funciona no celular e no PC).
      onStatus?.call('Convertendo para MP4…');
      try {
        await DavReader.toMp4(input, out,
            from: from,
            to: to,
            onProgress: (pr) =>
                onStatus?.call('Convertendo para MP4… ${(pr * 100).toStringAsFixed(0)}%'));
        return out;
      } catch (e) {
        if (await out.exists()) await out.delete();
        throw ConvertError('$e');
      }
    }

    if (Platform.isAndroid || Platform.isIOS) {
      throw ConvertError(
          'No celular só dá para converter arquivos .dav da câmera. Converta este no PC.');
    }
    onStatus?.call('Convertendo para MP4…');
    if (await _remux(input.path, out)) return out;

    // O áudio de algumas câmeras (G.711) não cabe em MP4: salva só o vídeo.
    onStatus?.call('Convertendo para MP4 (sem áudio)…');
    if (await _remux(input.path, out, extra: const {'aid': 'no'})) return out;
    throw ConvertError('Não consegui converter esse vídeo para MP4.');
  }

  /// Usa o mpv do app para copiar as faixas para o arquivo de saída.
  /// Com o player pausado e cache em disco, ele lê o arquivo inteiro sem tocar.
  static Future<bool> _remux(String input, File out,
      {Map<String, String> extra = const {}}) async {
    if (await out.exists()) await out.delete();
    final tmp = await getTemporaryDirectory();
    final player = Player(
      configuration: const PlayerConfiguration(logLevel: MPVLogLevel.error),
    );
    var failed = false;
    final sub = player.stream.error.listen((_) => failed = true);
    // O gravador do mpv avisa no log quando o formato não aceita uma faixa.
    final logSub = player.stream.log.listen((l) {
      final lvl = l.level.toLowerCase();
      if ((lvl == 'error' || lvl == 'fatal') &&
          (l.prefix.contains('record') || l.text.toLowerCase().contains('record'))) {
        failed = true;
      }
    });
    try {
      for (final e in {
        'vo': 'null',
        'ao': 'null',
        'mute': 'yes',
        'vid': 'auto',
        'aid': 'auto',
        'cache': 'yes',
        'cache-on-disk': 'yes',
        'cache-dir': tmp.path,
        'cache-secs': '86400',
        'demuxer-readahead-secs': '86400',
        'demuxer-max-bytes': '4000MiB',
        'demuxer-max-back-bytes': '0',
        ...extra,
        'stream-record': out.path,
      }.entries) {
        await mpvSet(player, e.key, e.value);
      }
      await player.open(Media(input), play: false);

      var last = -1;
      var stable = 0;
      final started = DateTime.now();
      while (true) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (failed) break;
        final size = await out.exists() ? await out.length() : 0;
        final elapsed = DateTime.now().difference(started);
        if (size == 0 && elapsed > const Duration(seconds: 10)) {
          failed = true;
          break;
        }
        if (size > 0 && size == last) {
          stable++;
          if (stable >= 6) break; // 3 s sem crescer = terminou
        } else {
          stable = 0;
        }
        last = size;
        if (elapsed > const Duration(minutes: 20)) break;
      }
      await mpvSet(player, 'stream-record', '');
      await Future.delayed(const Duration(milliseconds: 300));
    } finally {
      await sub.cancel();
      await logSub.cancel();
      await player.dispose();
    }
    final ok = !failed && await out.exists() && await out.length() > 20 * 1024;
    if (!ok && await out.exists()) await out.delete();
    return ok;
  }
}
