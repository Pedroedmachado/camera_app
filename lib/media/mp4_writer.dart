// Gravador de MP4 próprio (H.264/H.265), sem depender do player.
// Escreve os quadros direto no arquivo e monta o índice (moov) no final.

import 'dart:io';
import 'dart:typed_data';

import 'nal.dart';

class Mp4Writer {
  Mp4Writer._(this.file, this._raf, this.codec);

  final File file;
  final RandomAccessFile _raf;
  final VideoCodec codec;

  final List<int> _sizes = [];
  final List<int> _offsets = [];
  final List<int> _times = [];
  final List<int> _keys = []; // índices (1-based) dos quadros-chave
  int _pos = 0;
  int? _t0;
  bool _closed = false;
  late final VideoParams params = VideoParams(codec);

  int get frames => _sizes.length;

  /// Duração gravada até agora, em ms.
  int get durationMs =>
      _times.isEmpty ? 0 : (_times.last - _times.first) + _lastDur();

  static Future<Mp4Writer> create(File file, VideoCodec codec) async {
    if (await file.exists()) await file.delete();
    final raf = await file.open(mode: FileMode.write);
    final w = Mp4Writer._(file, raf, codec);
    await w._writeHeader();
    return w;
  }

  Future<void> _writeHeader() async {
    final ftyp = _box('ftyp', [
      ..._ascii('isom'),
      ..._u32(0x200),
      ..._ascii('isom'),
      ..._ascii('iso2'),
      ..._ascii(codec == VideoCodec.h264 ? 'avc1' : 'hvc1'),
      ..._ascii('mp41'),
    ]);
    await _raf.writeFrom(ftyp);
    // mdat com tamanho de 64 bits (ajustado no final).
    await _raf.writeFrom([0, 0, 0, 1, ..._ascii('mdat'), 0, 0, 0, 0, 0, 0, 0, 0]);
    _pos = ftyp.length + 16;
  }

  /// Adiciona um quadro. Quadros antes do primeiro quadro-chave são ignorados.
  Future<void> add(VideoFrame f) async {
    if (_closed) return;
    final keep = <Uint8List>[];
    for (final n in f.nals) {
      final t = nalType(codec, n);
      if (isParamNal(codec, t)) {
        params.take(n);
        continue;
      }
      // Descarta delimitadores (AUD).
      if ((codec == VideoCodec.h264 && t == 9) || (codec == VideoCodec.h265 && t == 35)) {
        continue;
      }
      keep.add(n);
    }
    if (keep.isEmpty) return;
    if (_sizes.isEmpty && (!f.key || !params.ready)) return;
    final data = lengthPrefixed(keep);
    _t0 ??= f.timeMs;
    var t = f.timeMs - _t0!;
    if (_times.isNotEmpty && t <= _times.last) t = _times.last + 1;
    await _raf.writeFrom(data);
    _offsets.add(_pos);
    _sizes.add(data.length);
    _times.add(t);
    if (f.key) _keys.add(_sizes.length);
    _pos += data.length;
  }

  void takeParams(Iterable<Uint8List> nals) {
    for (final n in nals) {
      params.take(n);
    }
  }

  int _lastDur() {
    if (_times.length < 2) return 66;
    final d = _times.last - _times[_times.length - 2];
    return d > 0 ? d : 66;
  }

  /// Fecha o arquivo. Devolve false se não houve nenhum quadro válido.
  Future<bool> finish() async {
    if (_closed) return frames > 0;
    _closed = true;
    if (_sizes.isEmpty || !params.ready) {
      await _raf.close();
      if (await file.exists()) await file.delete();
      return false;
    }
    // Ajusta o tamanho do mdat.
    final mdatStart = _offsets.first - 16;
    final mdatSize = _pos - mdatStart;
    await _raf.setPosition(mdatStart + 8);
    await _raf.writeFrom(_u64(mdatSize));
    await _raf.setPosition(_pos);
    await _raf.writeFrom(_moov());
    await _raf.close();
    return true;
  }

  Future<void> cancel() async {
    if (_closed) return;
    _closed = true;
    await _raf.close();
    if (await file.exists()) await file.delete();
  }

  // ---------- caixas ----------

  Uint8List _moov() {
    final n = _sizes.length;
    final durs = List<int>.generate(
        n, (i) => i + 1 < n ? _times[i + 1] - _times[i] : _lastDur());
    final total = durs.fold<int>(0, (a, b) => a + b);
    final w = params.width, h = params.height;

    // stts com sequências iguais agrupadas
    final stts = <int>[];
    var entries = 0;
    var i = 0;
    while (i < n) {
      var j = i;
      while (j + 1 < n && durs[j + 1] == durs[i]) {
        j++;
      }
      stts.addAll(_u32(j - i + 1));
      stts.addAll(_u32(durs[i]));
      entries++;
      i = j + 1;
    }

    final cfg = params.config();
    final sampleEntry = _box(codec == VideoCodec.h264 ? 'avc1' : 'hvc1', [
      0, 0, 0, 0, 0, 0, 0, 1, // reservado + data_reference_index
      ...List.filled(16, 0),
      ..._u16(w), ..._u16(h),
      ..._u32(0x00480000), ..._u32(0x00480000),
      ..._u32(0),
      ..._u16(1),
      ...List.filled(32, 0),
      ..._u16(0x18), ..._u16(0xFFFF),
      ..._box(codec == VideoCodec.h264 ? 'avcC' : 'hvcC', cfg),
    ]);

    final stbl = _box('stbl', [
      ..._full('stsd', 0, 0, [..._u32(1), ...sampleEntry]),
      ..._full('stts', 0, 0, [..._u32(entries), ...stts]),
      ..._full('stss', 0, 0, [
        ..._u32(_keys.length),
        for (final k in _keys) ..._u32(k),
      ]),
      ..._full('stsc', 0, 0, [..._u32(1), ..._u32(1), ..._u32(1), ..._u32(1)]),
      ..._full('stsz', 0, 0, [
        ..._u32(0),
        ..._u32(n),
        for (final s in _sizes) ..._u32(s),
      ]),
      ..._full('co64', 0, 0, [
        ..._u32(n),
        for (final o in _offsets) ..._u64(o),
      ]),
    ]);

    final minf = _box('minf', [
      ..._full('vmhd', 0, 1, [0, 0, 0, 0, 0, 0, 0, 0]),
      ..._box('dinf', _full('dref', 0, 0, [..._u32(1), ..._full('url ', 0, 1, [])])),
      ...stbl,
    ]);

    final mdia = _box('mdia', [
      ..._full('mdhd', 0, 0, [
        ..._u32(0), ..._u32(0), ..._u32(1000), ..._u32(total), 0x55, 0xC4, 0, 0,
      ]),
      ..._full('hdlr', 0, 0, [
        ..._u32(0), ..._ascii('vide'), ...List.filled(12, 0), ..._ascii('Video'), 0,
      ]),
      ...minf,
    ]);

    final matrix = [
      ..._u32(0x00010000), ..._u32(0), ..._u32(0),
      ..._u32(0), ..._u32(0x00010000), ..._u32(0),
      ..._u32(0), ..._u32(0), ..._u32(0x40000000),
    ];

    final tkhd = _full('tkhd', 0, 3, [
      ..._u32(0), ..._u32(0), ..._u32(1), ..._u32(0), ..._u32(total),
      ...List.filled(8, 0), ..._u16(0), ..._u16(0), ..._u16(0), ..._u16(0),
      ...matrix,
      ..._u32(w << 16), ..._u32(h << 16),
    ]);

    final mvhd = _full('mvhd', 0, 0, [
      ..._u32(0), ..._u32(0), ..._u32(1000), ..._u32(total),
      ..._u32(0x00010000), ..._u16(0x0100), ...List.filled(10, 0),
      ...matrix,
      ...List.filled(24, 0),
      ..._u32(2),
    ]);

    return _box('moov', [...mvhd, ..._box('trak', [...tkhd, ...mdia])]);
  }

  static List<int> _ascii(String s) => s.codeUnits;
  static List<int> _u16(int v) => [(v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u32(int v) =>
      [(v >> 24) & 0xFF, (v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF];
  static List<int> _u64(int v) => [..._u32(v ~/ 0x100000000), ..._u32(v & 0xFFFFFFFF)];

  static Uint8List _box(String type, List<int> body) =>
      Uint8List.fromList([..._u32(body.length + 8), ..._ascii(type), ...body]);

  static Uint8List _full(String type, int version, int flags, List<int> body) =>
      _box(type, [version, (flags >> 16) & 0xFF, (flags >> 8) & 0xFF, flags & 0xFF, ...body]);
}
