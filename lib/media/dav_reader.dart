// Leitor do formato .dav da Dahua/Intelbras e conversão direta para MP4.
// Blocos "DHAV": cabeçalho de 24 bytes + extensão + dados + "dhav" + tamanho.

import 'dart:io';
import 'dart:typed_data';

import 'mp4_writer.dart';
import 'nal.dart';

class DavFrame {
  final VideoFrame frame;
  final DateTime? wallTime; // hora gravada pela câmera
  DavFrame(this.frame, this.wallTime);
}

class DavInfo {
  final VideoCodec codec;
  final int frames;
  final int durationMs;
  final DateTime? start;
  DavInfo(this.codec, this.frames, this.durationMs, this.start);
}

class DavReader {
  /// Lê os quadros de vídeo do arquivo, na ordem.
  static Stream<DavFrame> frames(File dav) async* {
    final raf = await dav.open();
    final total = await raf.length();
    const chunk = 1 << 20;
    var buf = Uint8List(0);
    var bufPos = 0; // posição no arquivo do início de buf
    var filePos = 0;
    int? lastMs16;
    var timeMs = 0;
    var started = false;

    Future<bool> ensure(int fileOffset, int len) async {
      while (fileOffset + len > bufPos + buf.length) {
        if (filePos >= total) return false;
        final keepFrom = fileOffset - bufPos;
        final more = await raf.read(chunk);
        filePos += more.length;
        final nb = Uint8List(buf.length - keepFrom + more.length);
        nb.setRange(0, buf.length - keepFrom, buf, keepFrom);
        nb.setRange(buf.length - keepFrom, nb.length, more);
        buf = nb;
        bufPos = fileOffset;
        if (more.isEmpty) return false;
      }
      return true;
    }

    var pos = 0;
    try {
      while (true) {
        if (!await ensure(pos, 24)) break;
        var i = pos - bufPos;
        if (!(buf[i] == 0x44 && buf[i + 1] == 0x48 && buf[i + 2] == 0x41 && buf[i + 3] == 0x56)) {
          pos++; // procura o próximo "DHAV"
          continue;
        }
        final bd = ByteData.sublistView(buf, i, i + 24);
        final type = buf[i + 4];
        final len = bd.getUint32(12, Endian.little);
        final extLen = buf[i + 22];
        if (len < 24 + extLen + 8 || len > 16 * 1024 * 1024) {
          pos += 4;
          continue;
        }
        if (!await ensure(pos, len)) break;
        i = pos - bufPos;
        if (type == 0xFD || type == 0xFC || type == 0xFB) {
          final b2 = ByteData.sublistView(buf, i, i + 24);
          final ms16 = b2.getUint16(20, Endian.little);
          final dt = b2.getUint32(16, Endian.little);
          if (lastMs16 != null) {
            var d = (ms16 - lastMs16) & 0xFFFF;
            if (d == 0 || d > 2000) d = 66;
            timeMs += d;
          }
          lastMs16 = ms16;
          final payload = Uint8List.sublistView(buf, i + 24 + extLen, i + len - 8);
          final nals = [for (final n in splitAnnexB(payload)) Uint8List.fromList(n)];
          if (nals.isNotEmpty) {
            final key = type == 0xFD;
            if (key) started = true;
            if (started) yield DavFrame(VideoFrame(nals, timeMs, key), _wall(dt));
          }
        }
        pos += len;
      }
    } finally {
      await raf.close();
    }
  }

  static DateTime? _wall(int v) {
    final sec = v & 0x3F;
    final min = (v >> 6) & 0x3F;
    final hour = (v >> 12) & 0x1F;
    final day = (v >> 17) & 0x1F;
    final month = (v >> 22) & 0x0F;
    final year = (v >> 26) + 2000;
    if (month < 1 || month > 12 || day < 1 || hour > 23 || min > 59 || sec > 59) return null;
    return DateTime(year, month, day, hour, min, sec);
  }

  /// Descobre se o vídeo é H.264 ou H.265 olhando o primeiro quadro-chave.
  static VideoCodec detect(List<Uint8List> nals) {
    for (final n in nals) {
      if (n.isEmpty) continue;
      final h265 = (n[0] >> 1) & 0x3F;
      if (h265 == 32) return VideoCodec.h265; // VPS
      if ((n[0] & 0x1F) == 7) return VideoCodec.h264; // SPS
    }
    for (final n in nals) {
      if (n.length > 1 && ((n[0] >> 1) & 0x3F) >= 16 && ((n[0] >> 1) & 0x3F) <= 21 && n[1] == 1) {
        return VideoCodec.h265;
      }
    }
    return VideoCodec.h264;
  }

  /// Converte .dav → .mp4 (sem recodificar). [from]/[to] cortam pelo
  /// horário da câmera (começa no quadro-chave anterior a [from]).
  static Future<DavInfo> toMp4(
    File dav,
    File out, {
    DateTime? from,
    DateTime? to,
    void Function(double progress)? onProgress,
  }) async {
    final total = await dav.length();
    Mp4Writer? w;
    VideoCodec? codec;
    DateTime? first;
    var count = 0;
    final pendingGop = <DavFrame>[]; // GOP atual antes de [from]
    var bytesSeen = 0;
    var lastReport = DateTime.now();

    Future<void> write(DavFrame f) async {
      codec ??= detect(f.frame.nals);
      w ??= await Mp4Writer.create(out, codec!);
      first ??= f.wallTime;
      await w!.add(f.frame);
      count++;
    }

    await for (final f in frames(dav)) {
      for (final n in f.frame.nals) {
        bytesSeen += n.length + 4;
      }
      if (onProgress != null && DateTime.now().difference(lastReport).inMilliseconds > 250) {
        lastReport = DateTime.now();
        onProgress((bytesSeen / total).clamp(0.0, 1.0));
      }
      final wt = f.wallTime;
      if (to != null && wt != null && wt.isAfter(to) && count > 0) break;
      if (from != null && w == null) {
        // Guarda o GOP até chegar ao horário pedido.
        if (f.frame.key) pendingGop.clear();
        pendingGop.add(f);
        if (wt == null || wt.isBefore(from)) continue;
        for (final g in pendingGop) {
          await write(g);
        }
        pendingGop.clear();
        continue;
      }
      await write(f);
    }
    if (w == null && pendingGop.isNotEmpty) {
      for (final g in pendingGop) {
        await write(g);
      }
    }
    if (w == null) throw StateError('Não achei vídeo dentro do arquivo da câmera.');
    final dur = w!.durationMs;
    if (!await w!.finish()) {
      throw StateError('Não consegui montar o MP4 (faltam parâmetros do vídeo).');
    }
    onProgress?.call(1);
    return DavInfo(codec!, count, dur, first);
  }
}
