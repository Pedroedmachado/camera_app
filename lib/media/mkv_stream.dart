// Muxer Matroska (MKV) para transmissão ao vivo: o app entrega o vídeo da
// câmera ao player neste formato, que todo libmpv entende.

import 'dart:typed_data';

import 'nal.dart';

class MkvLiveMuxer {
  MkvLiveMuxer(this.params, {this.audioRate});

  final VideoParams params;
  final int? audioRate; // null = sem áudio

  int? _clusterTime;
  int? _t0;

  /// Cabeçalho do arquivo (EBML + início do Segment + Info + Tracks).
  Uint8List header() {
    final ebml = _el(0x1A45DFA3, [
      ..._uint(0x4286, 1),
      ..._uint(0x42F7, 1),
      ..._uint(0x42F2, 4),
      ..._uint(0x42F3, 8),
      ..._str(0x4282, 'matroska'),
      ..._uint(0x4287, 4),
      ..._uint(0x4285, 2),
    ]);
    final info = _el(0x1549A966, [
      ..._uint(0x2AD7B1, 1000000), // escala em ms
      ..._str(0x4D80, 'CamLivre'),
      ..._str(0x5741, 'CamLivre'),
    ]);
    final video = _el(0xAE, [
      ..._uint(0xD7, 1),
      ..._uint(0x73C5, 1),
      ..._uint(0x83, 1),
      ..._uint(0x9C, 0),
      ..._str(0x86, params.codec == VideoCodec.h264 ? 'V_MPEG4/ISO/AVC' : 'V_MPEGH/ISO/HEVC'),
      ..._el(0x63A2, params.config()),
      ..._el(0xE0, [
        ..._uint(0xB0, params.width),
        ..._uint(0xBA, params.height),
      ]),
    ]);
    final tracks = <int>[...video];
    if (audioRate != null) {
      tracks.addAll(_el(0xAE, [
        ..._uint(0xD7, 2),
        ..._uint(0x73C5, 2),
        ..._uint(0x83, 2),
        ..._uint(0x9C, 0),
        ..._str(0x86, 'A_PCM/INT/LIT'),
        ..._el(0xE1, [
          ..._float(0xB5, audioRate!.toDouble()),
          ..._uint(0x9F, 1),
          ..._uint(0x6264, 16),
        ]),
      ]));
    }
    return Uint8List.fromList([
      ...ebml,
      ..._id(0x18538067), 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, // Segment (tamanho desconhecido)
      ...info,
      ..._el(0x1654AE6B, tracks),
    ]);
  }

  Uint8List _cluster(int t) {
    _clusterTime = t;
    return Uint8List.fromList([
      ..._id(0x1F43B675), 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF,
      ..._uint(0xE7, t),
    ]);
  }

  int _rel(int timeMs) {
    _t0 ??= timeMs;
    return timeMs - _t0!;
  }

  /// Bytes de um quadro de vídeo (abre um cluster novo em cada quadro-chave).
  Uint8List video(VideoFrame f) {
    final t = _rel(f.timeMs);
    final out = BytesBuilder(copy: false);
    if (_clusterTime == null || f.key || t - _clusterTime! > 30000 || t < _clusterTime!) {
      out.add(_cluster(t));
    }
    final nals = [
      for (final n in f.nals)
        if (!((params.codec == VideoCodec.h264 && nalType(params.codec, n) == 9) ||
            (params.codec == VideoCodec.h265 && nalType(params.codec, n) == 35)))
          n
    ];
    out.add(_block(1, t - _clusterTime!, f.key, lengthPrefixed(nals)));
    return out.toBytes();
  }

  /// Bytes de um bloco de áudio PCM.
  Uint8List? audio(AudioChunk a) {
    if (audioRate == null || _clusterTime == null) return null;
    final rel = _rel(a.timeMs) - _clusterTime!;
    if (rel < -32000 || rel > 32000) return null;
    return _block(2, rel, true, a.pcm);
  }

  Uint8List _block(int track, int rel, bool key, Uint8List data) {
    final head = [
      0x80 | track,
      (rel >> 8) & 0xFF,
      rel & 0xFF,
      key ? 0x80 : 0x00,
    ];
    return Uint8List.fromList([
      ..._id(0xA3),
      ..._size(head.length + data.length),
      ...head,
      ...data,
    ]);
  }

  // ---------- EBML ----------

  static List<int> _id(int id) {
    if (id > 0xFFFFFF) return [(id >> 24) & 0xFF, (id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF];
    if (id > 0xFFFF) return [(id >> 16) & 0xFF, (id >> 8) & 0xFF, id & 0xFF];
    if (id > 0xFF) return [(id >> 8) & 0xFF, id & 0xFF];
    return [id];
  }

  static List<int> _size(int n) {
    for (var len = 1; len <= 8; len++) {
      if (n < (1 << (7 * len)) - 1) {
        final out = List<int>.filled(len, 0);
        var v = n;
        for (var i = len - 1; i >= 0; i--) {
          out[i] = v & 0xFF;
          v >>= 8;
        }
        out[0] |= 1 << (8 - len);
        return out;
      }
    }
    throw ArgumentError('tamanho grande demais');
  }

  static List<int> _el(int id, List<int> body) => [..._id(id), ..._size(body.length), ...body];

  static List<int> _uint(int id, int v) {
    final bytes = <int>[];
    var x = v;
    do {
      bytes.insert(0, x & 0xFF);
      x >>= 8;
    } while (x > 0);
    return _el(id, bytes);
  }

  static List<int> _str(int id, String s) => _el(id, s.codeUnits);

  static List<int> _float(int id, double v) {
    final b = ByteData(8)..setFloat64(0, v);
    return _el(id, b.buffer.asUint8List());
  }
}
