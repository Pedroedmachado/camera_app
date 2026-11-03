// Utilidades de H.264 / H.265: separar NALs, ler SPS e montar avcC/hvcC.
// Código Dart puro (sem Flutter), usado no ao vivo, na gravação e na conversão.

import 'dart:typed_data';

enum VideoCodec { h264, h265 }

/// Um quadro de vídeo (access unit) já separado em NALs, sem start codes.
class VideoFrame {
  final List<Uint8List> nals;
  final int timeMs; // tempo de apresentação em milissegundos
  final bool key;
  VideoFrame(this.nals, this.timeMs, this.key);
}

/// Bloco de áudio PCM 16 bits mono (little-endian).
class AudioChunk {
  final Uint8List pcm;
  final int timeMs;
  final int sampleRate;
  AudioChunk(this.pcm, this.timeMs, this.sampleRate);
}

int nalType(VideoCodec c, Uint8List nal) {
  if (nal.isEmpty) return -1;
  return c == VideoCodec.h264 ? nal[0] & 0x1F : (nal[0] >> 1) & 0x3F;
}

bool isKeyNal(VideoCodec c, int t) =>
    c == VideoCodec.h264 ? t == 5 : (t >= 16 && t <= 21);

bool isParamNal(VideoCodec c, int t) =>
    c == VideoCodec.h264 ? (t == 7 || t == 8) : (t >= 32 && t <= 34);

/// Separa um fluxo Annex-B (00 00 01 / 00 00 00 01) em NALs.
List<Uint8List> splitAnnexB(Uint8List d) {
  final out = <Uint8List>[];
  var i = 0;
  var start = -1;
  final n = d.length;
  while (i + 2 < n) {
    if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) {
      if (start >= 0) {
        var end = i;
        while (end > start && d[end - 1] == 0) {
          end--;
        }
        if (end > start) out.add(Uint8List.sublistView(d, start, end));
      }
      i += 3;
      start = i;
      continue;
    }
    i++;
  }
  if (start >= 0 && start < n) {
    out.add(Uint8List.sublistView(d, start, n));
  }
  return out;
}

/// Remove os bytes de prevenção de emulação (00 00 03 → 00 00).
Uint8List unescapeRbsp(Uint8List d, [int from = 0]) {
  final b = BytesBuilder(copy: false);
  var zeros = 0;
  final out = <int>[];
  for (var i = from; i < d.length; i++) {
    final v = d[i];
    if (zeros >= 2 && v == 3) {
      zeros = 0;
      continue;
    }
    out.add(v);
    zeros = v == 0 ? zeros + 1 : 0;
  }
  b.add(out);
  return b.toBytes();
}

class BitReader {
  BitReader(this._d);
  final Uint8List _d;
  int _pos = 0;

  int bit() {
    final byte = _pos >> 3;
    if (byte >= _d.length) throw RangeError('fim do SPS');
    final v = (_d[byte] >> (7 - (_pos & 7))) & 1;
    _pos++;
    return v;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  void skip(int n) => _pos += n;

  int ue() {
    var zeros = 0;
    while (bit() == 0) {
      zeros++;
      if (zeros > 31) throw RangeError('ue inválido');
    }
    if (zeros == 0) return 0;
    return (1 << zeros) - 1 + bits(zeros);
  }

  int se() {
    final k = ue();
    return (k & 1) == 1 ? (k + 1) >> 1 : -(k >> 1);
  }
}

class SpsInfo {
  final int width;
  final int height;
  SpsInfo(this.width, this.height);
}

/// Lê largura/altura do SPS H.264.
SpsInfo? parseH264Sps(Uint8List nal) {
  try {
    final r = BitReader(unescapeRbsp(nal, 1));
    final profile = r.bits(8);
    r.skip(16); // constraint flags + level
    r.ue(); // sps id
    var chroma = 1;
    if (const [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
        .contains(profile)) {
      chroma = r.ue();
      if (chroma == 3) r.skip(1);
      r.ue(); // bit depth luma
      r.ue(); // bit depth chroma
      r.skip(1); // qpprime
      if (r.bit() == 1) {
        final count = chroma != 3 ? 8 : 12;
        for (var i = 0; i < count; i++) {
          if (r.bit() == 1) {
            final size = i < 6 ? 16 : 64;
            var last = 8, next = 8;
            for (var j = 0; j < size; j++) {
              if (next != 0) {
                next = (last + r.se() + 256) % 256;
              }
              last = next == 0 ? last : next;
            }
          }
        }
      }
    }
    r.ue(); // log2_max_frame_num
    final pocType = r.ue();
    if (pocType == 0) {
      r.ue();
    } else if (pocType == 1) {
      r.skip(1);
      r.se();
      r.se();
      final n = r.ue();
      for (var i = 0; i < n; i++) {
        r.se();
      }
    }
    r.ue(); // max ref frames
    r.skip(1);
    final wMbs = r.ue() + 1;
    final hMapUnits = r.ue() + 1;
    final frameMbsOnly = r.bit();
    if (frameMbsOnly == 0) r.skip(1);
    r.skip(1); // direct_8x8
    var w = wMbs * 16;
    var h = (2 - frameMbsOnly) * hMapUnits * 16;
    if (r.bit() == 1) {
      final l = r.ue(), rr = r.ue(), t = r.ue(), b = r.ue();
      final cx = chroma == 0 ? 1 : (chroma == 3 ? 1 : 2);
      final cy = (chroma == 1 ? 2 : 1) * (2 - frameMbsOnly);
      w -= (l + rr) * cx;
      h -= (t + b) * cy;
    }
    return SpsInfo(w, h);
  } catch (_) {
    return null;
  }
}

/// Dados do SPS H.265 necessários para o hvcC e o tamanho da imagem.
class HevcSps {
  final Uint8List ptl; // 12 bytes de profile/tier/level geral
  final int chromaFormat;
  final int bitDepthLuma;
  final int bitDepthChroma;
  final int width;
  final int height;
  final int maxSubLayers;
  final bool temporalIdNesting;
  HevcSps(this.ptl, this.chromaFormat, this.bitDepthLuma, this.bitDepthChroma,
      this.width, this.height, this.maxSubLayers, this.temporalIdNesting);
}

HevcSps? parseH265Sps(Uint8List nal) {
  try {
    final rbsp = unescapeRbsp(nal, 2);
    final r = BitReader(rbsp);
    r.skip(4); // vps id
    final maxSubLayersMinus1 = r.bits(3);
    final nesting = r.bit() == 1;
    final ptl = Uint8List(12);
    for (var i = 0; i < 12; i++) {
      ptl[i] = r.bits(8);
    }
    // sub-layers
    final subProfile = <bool>[];
    final subLevel = <bool>[];
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      subProfile.add(r.bit() == 1);
      subLevel.add(r.bit() == 1);
    }
    if (maxSubLayersMinus1 > 0) {
      for (var i = maxSubLayersMinus1; i < 8; i++) {
        r.skip(2);
      }
    }
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      if (subProfile[i]) r.skip(88);
      if (subLevel[i]) r.skip(8);
    }
    r.ue(); // sps id
    final chroma = r.ue();
    if (chroma == 3) r.skip(1);
    var w = r.ue();
    var h = r.ue();
    if (r.bit() == 1) {
      final l = r.ue(), rr = r.ue(), t = r.ue(), b = r.ue();
      final cx = (chroma == 1 || chroma == 2) ? 2 : 1;
      final cy = chroma == 1 ? 2 : 1;
      w -= (l + rr) * cx;
      h -= (t + b) * cy;
    }
    final bdl = r.ue() + 8;
    final bdc = r.ue() + 8;
    return HevcSps(ptl, chroma, bdl, bdc, w, h, maxSubLayersMinus1 + 1, nesting);
  } catch (_) {
    return null;
  }
}

/// Parâmetros do vídeo (SPS/PPS/VPS) e o "codec private" para MP4/MKV.
class VideoParams {
  VideoParams(this.codec);
  final VideoCodec codec;
  Uint8List? vps, sps, pps;

  bool get ready =>
      sps != null && pps != null && (codec == VideoCodec.h264 || vps != null);

  /// Guarda os NALs de parâmetro; devolve true se algo mudou.
  bool take(Uint8List nal) {
    final t = nalType(codec, nal);
    final copy = Uint8List.fromList(nal);
    bool changed(Uint8List? old) =>
        old == null || old.length != copy.length || !_same(old, copy);
    if (codec == VideoCodec.h264) {
      if (t == 7 && changed(sps)) {
        sps = copy;
        return true;
      }
      if (t == 8 && changed(pps)) {
        pps = copy;
        return true;
      }
    } else {
      if (t == 32 && changed(vps)) {
        vps = copy;
        return true;
      }
      if (t == 33 && changed(sps)) {
        sps = copy;
        return true;
      }
      if (t == 34 && changed(pps)) {
        pps = copy;
        return true;
      }
    }
    return false;
  }

  static bool _same(Uint8List a, Uint8List b) {
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  int get width {
    if (sps == null) return 0;
    return codec == VideoCodec.h264
        ? (parseH264Sps(sps!)?.width ?? 0)
        : (parseH265Sps(sps!)?.width ?? 0);
  }

  int get height {
    if (sps == null) return 0;
    return codec == VideoCodec.h264
        ? (parseH264Sps(sps!)?.height ?? 0)
        : (parseH265Sps(sps!)?.height ?? 0);
  }

  /// avcC (H.264) ou hvcC (H.265).
  Uint8List config() {
    final b = BytesBuilder();
    void u16(int v) => b.add([(v >> 8) & 0xFF, v & 0xFF]);
    if (codec == VideoCodec.h264) {
      final s = sps!, p = pps!;
      b.add([1, s[1], s[2], s[3], 0xFF, 0xE1]);
      u16(s.length);
      b.add(s);
      b.addByte(1);
      u16(p.length);
      b.add(p);
      return b.toBytes();
    }
    final info = parseH265Sps(sps!);
    final ptl = info?.ptl ?? Uint8List(12);
    b.addByte(1); // version
    b.add(ptl.sublist(0, 1)); // profile_space, tier, profile_idc
    b.add(ptl.sublist(1, 5)); // compatibility flags
    b.add(ptl.sublist(5, 11)); // constraint flags
    b.add(ptl.sublist(11, 12)); // level
    u16(0xF000); // min_spatial_segmentation
    b.addByte(0xFC); // parallelism
    b.addByte(0xFC | ((info?.chromaFormat ?? 1) & 3));
    b.addByte(0xF8 | (((info?.bitDepthLuma ?? 8) - 8) & 7));
    b.addByte(0xF8 | (((info?.bitDepthChroma ?? 8) - 8) & 7));
    u16(0); // avg frame rate
    b.addByte(((info?.maxSubLayers ?? 1) & 7) << 3 |
        ((info?.temporalIdNesting ?? true) ? 1 << 2 : 0) |
        3); // lengthSizeMinusOne = 3
    b.addByte(3); // número de arrays
    for (final e in [
      [32, vps!],
      [33, sps!],
      [34, pps!],
    ]) {
      b.addByte(0x80 | (e[0] as int)); // array_completeness=1
      u16(1);
      final n = e[1] as Uint8List;
      u16(n.length);
      b.add(n);
    }
    return b.toBytes();
  }
}

/// Junta NALs no formato de amostra MP4/MKV (tamanho de 4 bytes + NAL).
Uint8List lengthPrefixed(List<Uint8List> nals) {
  var total = 0;
  for (final n in nals) {
    total += 4 + n.length;
  }
  final out = Uint8List(total);
  var o = 0;
  for (final n in nals) {
    out[o] = (n.length >> 24) & 0xFF;
    out[o + 1] = (n.length >> 16) & 0xFF;
    out[o + 2] = (n.length >> 8) & 0xFF;
    out[o + 3] = n.length & 0xFF;
    out.setRange(o + 4, o + 4 + n.length, n);
    o += 4 + n.length;
  }
  return out;
}

// ---------- G.711 → PCM ----------

int alawToLinear(int a) {
  a ^= 0x55;
  var t = (a & 0x0F) << 4;
  final seg = (a & 0x70) >> 4;
  switch (seg) {
    case 0:
      t += 8;
      break;
    case 1:
      t += 0x108;
      break;
    default:
      t += 0x108;
      t <<= seg - 1;
  }
  return (a & 0x80) != 0 ? t : -t;
}

int ulawToLinear(int u) {
  u = ~u & 0xFF;
  var t = ((u & 0x0F) << 3) + 0x84;
  t <<= (u & 0x70) >> 4;
  return (u & 0x80) != 0 ? (0x84 - t) : (t - 0x84);
}

Uint8List g711ToPcm(Uint8List data, {required bool ulaw}) {
  final out = Uint8List(data.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < data.length; i++) {
    final v = ulaw ? ulawToLinear(data[i]) : alawToLinear(data[i]);
    bd.setInt16(i * 2, v, Endian.little);
  }
  return out;
}
