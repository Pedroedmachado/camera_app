import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'player_util.dart';

class ConvertError implements Exception {
  final String message;
  ConvertError(this.message);
  @override
  String toString() => message;
}

/// Converte gravações (.dav da câmera ou .mkv) em MP4, que abre em qualquer
/// celular, PC e no WhatsApp. Não recodifica o vídeo: sem perda de qualidade.
class VideoConverter {
  /// [duration] = duração real da gravação (usada no plano C para acertar a velocidade).
  static Future<File> toMp4(
    File input,
    File out, {
    Duration? duration,
    void Function(String status)? onStatus,
  }) async {
    onStatus?.call('Convertendo para MP4…');
    if (await _remux(input.path, out)) return out;

    // O áudio de algumas câmeras (G.711) não cabe em MP4: salva só o vídeo.
    onStatus?.call('Convertendo para MP4 (sem áudio)…');
    if (await _remux(input.path, out, extra: const {'aid': 'no'})) return out;

    if (!input.path.toLowerCase().endsWith('.dav')) {
      throw ConvertError('Não consegui converter esse vídeo para MP4.');
    }

    // Plano C: extrai o vídeo puro de dentro do .dav e empacota de novo.
    onStatus?.call('Convertendo (modo alternativo)…');
    final tmp = await getTemporaryDirectory();
    final es = await DavExtractor.extract(
        input, File(p.join(tmp.path, 'camlivre_${DateTime.now().microsecondsSinceEpoch}.es')));
    try {
      if (es.frames == 0) {
        throw ConvertError('Não achei vídeo dentro do arquivo da câmera.');
      }
      final secs = (duration?.inMilliseconds ?? 0) / 1000.0;
      final fps = secs > 1 ? (es.frames / secs).clamp(1.0, 60.0) : 15.0;
      final ok = await _remux(es.file.path, out, extra: {
        'aid': 'no',
        'demuxer-lavf-format': es.hevc ? 'hevc' : 'h264',
        'demuxer-lavf-o': 'framerate=${fps.toStringAsFixed(3)}',
      });
      if (!ok) throw ConvertError('Não consegui converter esse vídeo.');
      return out;
    } finally {
      if (await es.file.exists()) await es.file.delete();
    }
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

class DavStream {
  final File file;
  final int frames;
  final bool hevc;
  DavStream(this.file, this.frames, this.hevc);
}

/// Lê o formato DAV da Dahua: blocos "DHAV" (cabeçalho de 24 bytes +
/// extensão + dados + "dhav" e tamanho). Junta só os quadros de vídeo.
class DavExtractor {
  static const _magic = [0x44, 0x48, 0x41, 0x56]; // "DHAV"

  static Future<DavStream> extract(File dav, File out) async {
    final raf = await dav.open();
    final sink = out.openWrite();
    final total = await raf.length();
    var pos = 0;
    var frames = 0;
    bool? hevc;
    try {
      while (pos + 24 <= total) {
        await raf.setPosition(pos);
        final h = await raf.read(24);
        if (h.length < 24) break;
        if (!_isMagic(h, 0)) {
          final next = await _findMagic(raf, pos + 1, total);
          if (next < 0) break;
          pos = next;
          continue;
        }
        final bd = ByteData.sublistView(h);
        final type = h[4];
        final frameLen = bd.getUint32(12, Endian.little);
        final extLen = h[22];
        if (frameLen < 24 + extLen + 8 || pos + frameLen > total) {
          pos += 4; // bloco quebrado: procura o próximo
          continue;
        }
        if (type == 0xFC || type == 0xFD) {
          final payloadLen = frameLen - 24 - extLen - 8;
          await raf.setPosition(pos + 24 + extLen);
          final data = await raf.read(payloadLen);
          hevc ??= _detectHevc(data);
          sink.add(data);
          frames++;
        }
        pos += frameLen;
      }
    } finally {
      await raf.close();
      await sink.close();
    }
    return DavStream(out, frames, hevc ?? false);
  }

  static bool _isMagic(List<int> b, int i) =>
      b.length >= i + 4 &&
      b[i] == _magic[0] &&
      b[i + 1] == _magic[1] &&
      b[i + 2] == _magic[2] &&
      b[i + 3] == _magic[3];

  static Future<int> _findMagic(RandomAccessFile raf, int from, int total) async {
    const window = 64 * 1024;
    var start = from;
    while (start < total) {
      await raf.setPosition(start);
      final buf = await raf.read(window + 3);
      if (buf.isEmpty) return -1;
      for (var i = 0; i + 3 < buf.length; i++) {
        if (_isMagic(buf, i)) return start + i;
      }
      start += window;
    }
    return -1;
  }

  /// H.265 começa com VPS (tipo 32); H.264 com SPS (tipo 7).
  static bool _detectHevc(Uint8List d) {
    for (var i = 0; i + 4 < d.length && i < 4096; i++) {
      if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
        final b = d[i + 3];
        if (((b >> 1) & 0x3F) == 32) return true;
        if ((b & 0x1F) == 7) return false;
      }
    }
    return false;
  }
}
