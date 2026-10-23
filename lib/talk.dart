import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:record/record.dart';

import 'config.dart';
import 'rtsp_probe.dart';

class TalkError implements Exception {
  final String message;
  TalkError(this.message);
  @override
  String toString() => message;
}

/// Fala pela câmera usando o canal de volta do RTSP (ONVIF backchannel):
/// microfone → G.711 (PCMA/PCMU) → RTP intercalado no TCP do RTSP.
class TalkSession {
  TalkSession(this.cfg, {this.onEnded});

  final CameraConfig cfg;
  final void Function(String reason)? onEnded;

  static const _require = 'www.onvif.org/ver20/backchannel';

  Socket? _socket;
  RtspReader? _reader;
  AudioRecorder? _rec;
  StreamSubscription<Uint8List>? _mic;
  Timer? _keepAlive;

  String _challenge = '';
  int _cseq = 1;
  String? _session;
  String _base = '';

  int _pt = 8;
  bool _ulaw = false;
  int _rate = 8000;
  int _decim = 1;
  int _seq = Random().nextInt(0xFFFF);
  int _ts = Random().nextInt(0x7FFFFFFF);
  final int _ssrc = Random().nextInt(0x7FFFFFFF);
  final List<int> _pcm = [];
  int? _carry;
  bool _active = false;
  bool get active => _active;

  // ---------- RTSP ----------

  String _requestText(String method, String uri, Map<String, String> headers) {
    final b = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: ${_cseq++}\r\n'
        'User-Agent: CamLivre\r\n');
    if (_session != null) b.write('Session: $_session\r\n');
    if (_challenge.isNotEmpty) {
      final auth = RtspProbe.authHeader(_challenge, method, uri, cfg.user, cfg.password);
      if (auth != null) b.write('Authorization: $auth\r\n');
    }
    headers.forEach((k, v) => b.write('$k: $v\r\n'));
    b.write('\r\n');
    return b.toString();
  }

  Future<RtspResponse> _call(String method, String uri,
      [Map<String, String> headers = const {}]) async {
    for (var round = 0; round < 2; round++) {
      _socket!.write(_requestText(method, uri, headers));
      final res = await _reader!.next();
      if (res == null) throw TalkError('A câmera fechou a conexão.');
      if (res.status == 401 && round == 0) {
        _challenge = res.headers['www-authenticate'] ?? '';
        continue;
      }
      if (res.status == 401) {
        throw TalkError('Senha errada (confira em Configurações).');
      }
      if (res.status != 200) {
        throw TalkError('A câmera recusou $method (erro ${res.status}).');
      }
      return res;
    }
    throw TalkError('Falha de autenticação.');
  }

  String _join(String base, String control) {
    if (control.startsWith('rtsp://')) return control;
    if (control == '*' || control.isEmpty) return base;
    return base.endsWith('/') ? '$base$control' : '$base/$control';
  }

  /// Acha a faixa de áudio de volta (a que a câmera recebe).
  void _pickBackchannel(String sdp, String base) {
    final sections = <List<String>>[];
    for (final raw in sdp.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.startsWith('m=')) sections.add([line]);
      if (sections.isNotEmpty && !line.startsWith('m=')) sections.last.add(line);
    }
    final audios = sections.where((s) => s.first.startsWith('m=audio')).toList();
    if (audios.isEmpty) {
      throw TalkError('Esta câmera não ofereceu canal de voz (sem áudio de volta).');
    }
    List<String>? back;
    for (final a in audios) {
      if (a.contains('a=sendonly')) back = a;
    }
    back ??= audios.length > 1 ? audios.last : null;
    if (back == null) {
      throw TalkError(
          'A câmera não ofereceu canal de voz pelo RTSP. Verifique no Mibo Smart se a função de falar funciona nesta câmera.');
    }
    final mParts = back.first.split(' ');
    final pt = mParts.length > 3 ? int.tryParse(mParts[3]) ?? 8 : 8;
    String? codec;
    var rate = 8000;
    String control = '';
    for (final l in back) {
      if (l.startsWith('a=rtpmap:$pt ')) {
        final enc = l.split(' ')[1].split('/');
        codec = enc[0].toUpperCase();
        if (enc.length > 1) rate = int.tryParse(enc[1]) ?? 8000;
      }
      if (l.startsWith('a=control:')) control = l.substring(10).trim();
    }
    codec ??= pt == 0 ? 'PCMU' : (pt == 8 ? 'PCMA' : 'desconhecido');
    if (codec != 'PCMA' && codec != 'PCMU') {
      throw TalkError('A câmera pede a voz em $codec, que ainda não é suportado.');
    }
    _pt = pt;
    _ulaw = codec == 'PCMU';
    _rate = rate;
    _trackUri = _join(base, control);
  }

  String _trackUri = '';

  Future<void> start() async {
    if (_active) return;
    final rec = AudioRecorder();
    _rec = rec;
    if (!await rec.hasPermission()) {
      await _cleanup();
      throw TalkError('Permita o uso do microfone para falar pela câmera.');
    }
    final host = cfg.host.trim();
    try {
      _socket = await Socket.connect(host, cfg.port,
          timeout: const Duration(seconds: 5));
    } catch (_) {
      await _cleanup();
      throw TalkError('Não consegui conectar na câmera para falar.');
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _reader = RtspReader(_socket!);
    try {
      final uri = 'rtsp://$host:${cfg.port}${cfg.rtspPath(hd: false)}';
      final desc = await _call('DESCRIBE', uri,
          {'Accept': 'application/sdp', 'Require': _require});
      _base = desc.headers['content-base'] ?? desc.headers['content-location'] ?? uri;
      _pickBackchannel(desc.body, _base);

      final setup = await _call('SETUP', _trackUri, {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=0-1',
        'Require': _require,
      });
      final sess = setup.headers['session'];
      if (sess == null) throw TalkError('A câmera não abriu a sessão de voz.');
      _session = sess.split(';').first.trim();
      final m = RegExp(r'timeout=(\d+)').firstMatch(sess);
      final timeout = m == null ? 60 : int.parse(m.group(1)!);

      await _call('PLAY', _base, {'Range': 'npt=0.000-', 'Require': _require});
      _reader!.discard = true;

      final every = Duration(seconds: max(10, timeout ~/ 2));
      _keepAlive = Timer.periodic(every, (_) {
        try {
          _socket?.write(_requestText('GET_PARAMETER', _base, const {}));
        } catch (_) {}
      });

      await _startMic(rec);
      _active = true;
      _socket!.done.then((_) => _ended('A câmera encerrou a conversa.'),
          onError: (_) => _ended('A conexão de voz caiu.'));
    } catch (e) {
      await _cleanup();
      if (e is TalkError) rethrow;
      throw TalkError('Falha ao abrir a voz: $e');
    }
  }

  Future<void> _startMic(AudioRecorder rec) async {
    Stream<Uint8List> stream;
    try {
      stream = await rec.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _rate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
      ));
      _decim = 1;
    } catch (_) {
      // Alguns PCs não gravam em 8 kHz: grava em 16 kHz e reduz.
      stream = await rec.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: 16000,
        numChannels: 1,
      ));
      _decim = max(1, 16000 ~/ _rate);
    }
    _mic = stream.listen(_onMic, onError: (_) => _ended('O microfone parou.'));
  }

  void _onMic(Uint8List data) {
    var bytes = data;
    if (_carry != null) {
      bytes = Uint8List(data.length + 1)
        ..[0] = _carry!
        ..setRange(1, data.length + 1, data);
      _carry = null;
    }
    final n = bytes.length ~/ 2;
    if (bytes.length.isOdd) _carry = bytes.last;
    final bd = ByteData.sublistView(bytes);
    for (var i = 0; i < n; i += _decim) {
      var acc = 0;
      var cnt = 0;
      for (var k = 0; k < _decim && i + k < n; k++) {
        acc += bd.getInt16((i + k) * 2, Endian.little);
        cnt++;
      }
      // Leve ganho: o alto-falante da câmera é baixo.
      final v = (acc / cnt * 1.6).round().clamp(-32768, 32767).toInt();
      _pcm.add(v);
    }
    final frame = _rate ~/ 50; // 20 ms
    while (_pcm.length >= frame) {
      final payload = Uint8List(frame);
      for (var i = 0; i < frame; i++) {
        payload[i] = _ulaw ? _linearToUlaw(_pcm[i]) : _linearToAlaw(_pcm[i]);
      }
      _pcm.removeRange(0, frame);
      _sendRtp(payload, frame);
    }
  }

  void _sendRtp(Uint8List payload, int samples) {
    final s = _socket;
    if (s == null) return;
    final rtpLen = 12 + payload.length;
    final pkt = Uint8List(4 + rtpLen);
    final bd = ByteData.sublistView(pkt);
    pkt[0] = 0x24; // '$'
    pkt[1] = 0; // canal intercalado 0
    bd.setUint16(2, rtpLen);
    pkt[4] = 0x80; // RTP v2
    pkt[5] = _pt & 0x7F;
    bd.setUint16(6, _seq & 0xFFFF);
    bd.setUint32(8, _ts & 0xFFFFFFFF);
    bd.setUint32(12, _ssrc);
    pkt.setRange(16, 16 + payload.length, payload);
    _seq = (_seq + 1) & 0xFFFF;
    _ts = (_ts + samples) & 0xFFFFFFFF;
    try {
      s.add(pkt);
    } catch (_) {
      _ended('A conexão de voz caiu.');
    }
  }

  void _ended(String reason) {
    if (!_active) return;
    _active = false;
    _cleanup();
    onEnded?.call(reason);
  }

  Future<void> stop() async {
    if (!_active) {
      await _cleanup();
      return;
    }
    _active = false;
    try {
      if (_session != null) {
        _socket?.write(_requestText('TEARDOWN', _base, const {}));
        await _socket?.flush();
      }
    } catch (_) {}
    await _cleanup();
  }

  Future<void> _cleanup() async {
    _keepAlive?.cancel();
    _keepAlive = null;
    await _mic?.cancel();
    _mic = null;
    final rec = _rec;
    _rec = null;
    if (rec != null) {
      try {
        await rec.stop();
      } catch (_) {}
      await rec.dispose();
    }
    _socket?.destroy();
    _socket = null;
    _pcm.clear();
  }

  // ---------- G.711 (algoritmo de referência da Sun) ----------

  static const _segAEnd = [0x1F, 0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF];
  static const _segUEnd = [0x3F, 0x7F, 0xFF, 0x1FF, 0x3FF, 0x7FF, 0xFFF, 0x1FFF];

  static int _seg(int v, List<int> table) {
    for (var i = 0; i < table.length; i++) {
      if (v <= table[i]) return i;
    }
    return table.length;
  }

  static int _linearToAlaw(int pcm) {
    var v = pcm >> 3;
    int mask;
    if (v >= 0) {
      mask = 0xD5;
    } else {
      mask = 0x55;
      v = -v - 1;
    }
    final seg = _seg(v, _segAEnd);
    if (seg >= 8) return 0x7F ^ mask;
    var a = seg << 4;
    a |= seg < 2 ? (v >> 1) & 0x0F : (v >> seg) & 0x0F;
    return (a ^ mask) & 0xFF;
  }

  static int _linearToUlaw(int pcm) {
    var v = pcm >> 2;
    int mask;
    if (v < 0) {
      v = -v;
      mask = 0x7F;
    } else {
      mask = 0xFF;
    }
    if (v > 8159) v = 8159;
    v += 0x84 >> 2;
    final seg = _seg(v, _segUEnd);
    if (seg >= 8) return 0x7F ^ mask;
    final u = (seg << 4) | ((v >> (seg + 1)) & 0x0F);
    return (u ^ mask) & 0xFF;
  }
}
