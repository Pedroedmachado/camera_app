// Cliente RTSP próprio (vídeo H.264/H.265 + áudio G.711 por TCP intercalado).
// Recebe o vídeo da câmera sem depender do player.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../rtsp_probe.dart';
import 'nal.dart';

class RtspError implements Exception {
  final String message;
  RtspError(this.message);
  @override
  String toString() => message;
}

class _Track {
  String kind = ''; // video / audio
  int pt = -1;
  String codec = '';
  int clock = 90000;
  String control = '';
  Map<String, String> fmtp = {};
  bool sendOnly = false;
}

class RtspClient {
  RtspClient({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
    required this.path,
  });

  final String host;
  final int port;
  final String user;
  final String password;
  final String path;

  Socket? _socket;
  final _in = _ByteQueue();
  StreamSubscription? _sub;
  int _cseq = 1;
  String? _session;
  String _challenge = '';
  String _base = '';
  Timer? _keepAlive;
  bool _closed = false;

  late VideoCodec codec;
  late VideoParams params;
  int? audioRate;
  bool _ulaw = false;

  final _video = StreamController<VideoFrame>.broadcast();
  final _audio = StreamController<AudioChunk>.broadcast();
  final _done = Completer<String>();

  Stream<VideoFrame> get video => _video.stream;
  Stream<AudioChunk> get audio => _audio.stream;

  /// Completa com o motivo quando a conexão termina.
  Future<String> get done => _done.future;

  String get _url => 'rtsp://$host:$port$path';

  // ---------- conexão ----------

  Future<void> start() async {
    try {
      _socket = await Socket.connect(host, port, timeout: const Duration(seconds: 6));
    } catch (_) {
      throw RtspError('Não achei a câmera em $host:$port. Confira o IP e se está no mesmo Wi-Fi.');
    }
    _socket!.setOption(SocketOption.tcpNoDelay, true);
    _sub = _socket!.listen(
      _in.add,
      onDone: () {
        _in.close();
        _finish('A câmera encerrou a conexão.');
      },
      onError: (e) {
        _in.close();
        _finish('Conexão com a câmera caiu.');
      },
    );

    final desc = await _request('DESCRIBE', _url, {'Accept': 'application/sdp'});
    _base = desc.headers['content-base'] ?? desc.headers['content-location'] ?? _url;
    if (!_base.endsWith('/')) _base = '$_base/';
    final tracks = _parseSdp(desc.body);
    final v = tracks.where((t) => t.kind == 'video').toList();
    if (v.isEmpty) throw RtspError('A câmera não ofereceu vídeo.');
    final vt = v.first;
    if (vt.codec == 'H264') {
      codec = VideoCodec.h264;
    } else if (vt.codec == 'H265' || vt.codec == 'HEVC') {
      codec = VideoCodec.h265;
    } else {
      throw RtspError('Formato de vídeo da câmera não suportado (${vt.codec}).');
    }
    params = VideoParams(codec);
    _sdpParams(vt);

    var nextCh = 0;
    final channels = <int, _Track>{};
    Future<void> setup(_Track t) async {
      final uri = _join(t.control);
      final res = await _request('SETUP', uri, {
        'Transport': 'RTP/AVP/TCP;unicast;interleaved=$nextCh-${nextCh + 1}',
      });
      final s = res.headers['session'];
      if (s != null) {
        _session = s.split(';').first.trim();
        final m = RegExp(r'timeout=(\d+)').firstMatch(s);
        _timeout = m == null ? 60 : int.parse(m.group(1)!);
      }
      final tr = res.headers['transport'] ?? '';
      final m = RegExp(r'interleaved=(\d+)').firstMatch(tr);
      final ch = m == null ? nextCh : int.parse(m.group(1)!);
      channels[ch] = t;
      nextCh += 2;
    }

    await setup(vt);
    final at = tracks.where((t) =>
        t.kind == 'audio' && !t.sendOnly && (t.codec == 'PCMA' || t.codec == 'PCMU'));
    if (at.isNotEmpty) {
      try {
        await setup(at.first);
        audioRate = at.first.clock;
        _ulaw = at.first.codec == 'PCMU';
      } catch (_) {
        // Sem áudio, segue só com vídeo.
      }
    }

    await _request('PLAY', _base, {'Range': 'npt=0.000-'});
    _channels = channels;
    _keepAlive = Timer.periodic(Duration(seconds: (_timeout ~/ 2).clamp(10, 30)), (_) {
      if (_closed) return;
      try {
        _socket?.write(_text('GET_PARAMETER', _base, const {}));
      } catch (_) {}
    });
    unawaited(_readLoop());
  }

  int _timeout = 60;
  Map<int, _Track> _channels = {};

  String _join(String control) {
    if (control.isEmpty || control == '*') return _base;
    if (control.startsWith('rtsp://')) return control;
    return '$_base$control';
  }

  String _text(String method, String uri, Map<String, String> headers) {
    final b = StringBuffer('$method $uri RTSP/1.0\r\nCSeq: ${_cseq++}\r\nUser-Agent: CamLivre\r\n');
    if (_session != null) b.write('Session: $_session\r\n');
    if (_challenge.isNotEmpty) {
      final auth = RtspProbe.authHeader(_challenge, method, uri, user, password);
      if (auth != null) b.write('Authorization: $auth\r\n');
    }
    headers.forEach((k, v) => b.write('$k: $v\r\n'));
    b.write('\r\n');
    return b.toString();
  }

  Future<_Response> _request(String method, String uri, Map<String, String> headers) async {
    for (var round = 0; round < 2; round++) {
      _socket!.write(_text(method, uri, headers));
      final res = await _readResponse().timeout(const Duration(seconds: 8),
          onTimeout: () => throw RtspError('A câmera não respondeu ($method).'));
      if (res.status == 401 && round == 0) {
        final ch = res.allAuth;
        _challenge = ch.firstWhere((c) => c.toLowerCase().startsWith('digest'),
            orElse: () => ch.isEmpty ? '' : ch.first);
        continue;
      }
      if (res.status == 401) {
        throw RtspError('Senha errada. Use a chave de acesso da câmera (usuário admin).');
      }
      if (res.status != 200) {
        throw RtspError('A câmera recusou $method (erro ${res.status}).');
      }
      return res;
    }
    throw RtspError('Falha no login com a câmera.');
  }

  /// Lê uma resposta RTSP de texto (pulando pacotes binários no meio).
  Future<_Response> _readResponse() async {
    while (true) {
      final first = await _in.peek(1);
      if (first == null) throw RtspError('A câmera fechou a conexão.');
      if (first[0] == 0x24) {
        final h = await _in.read(4);
        if (h == null) throw RtspError('A câmera fechou a conexão.');
        final len = (h[2] << 8) | h[3];
        await _in.read(len);
        continue;
      }
      final head = await _in.readUntilCrlf2();
      if (head == null) throw RtspError('A câmera fechou a conexão.');
      final text = latin1.decode(head);
      final lines = text.split('\r\n');
      final parts = lines.first.split(' ');
      final status = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      final headers = <String, String>{};
      final auth = <String>[];
      for (final l in lines.skip(1)) {
        final i = l.indexOf(':');
        if (i <= 0) continue;
        final k = l.substring(0, i).trim().toLowerCase();
        final v = l.substring(i + 1).trim();
        if (k == 'www-authenticate') auth.add(v);
        headers[k] = v;
      }
      final len = int.tryParse(headers['content-length'] ?? '0') ?? 0;
      final body = len > 0 ? await _in.read(len) : Uint8List(0);
      return _Response(status, headers, auth, utf8.decode(body ?? [], allowMalformed: true));
    }
  }

  List<_Track> _parseSdp(String sdp) {
    final out = <_Track>[];
    _Track? cur;
    for (final raw in const LineSplitter().convert(sdp)) {
      final l = raw.trim();
      if (l.startsWith('m=')) {
        final p = l.substring(2).split(' ');
        cur = _Track()
          ..kind = p.first
          ..pt = p.length > 3 ? int.tryParse(p[3]) ?? -1 : -1;
        if (cur.pt == 0) {
          cur.codec = 'PCMU';
          cur.clock = 8000;
        }
        if (cur.pt == 8) {
          cur.codec = 'PCMA';
          cur.clock = 8000;
        }
        out.add(cur);
        continue;
      }
      if (cur == null) continue;
      if (l.startsWith('a=rtpmap:')) {
        final m = RegExp(r'a=rtpmap:(\d+)\s+([^/]+)/(\d+)').firstMatch(l);
        if (m != null && int.parse(m.group(1)!) == cur.pt) {
          cur.codec = m.group(2)!.toUpperCase();
          cur.clock = int.parse(m.group(3)!);
        }
      } else if (l.startsWith('a=fmtp:')) {
        final sp = l.indexOf(' ');
        if (sp > 0) {
          for (final kv in l.substring(sp + 1).split(';')) {
            final i = kv.indexOf('=');
            if (i > 0) cur.fmtp[kv.substring(0, i).trim().toLowerCase()] = kv.substring(i + 1).trim();
          }
        }
      } else if (l.startsWith('a=control:')) {
        cur.control = l.substring(10).trim();
      } else if (l == 'a=sendonly') {
        cur.sendOnly = true;
      }
    }
    return out;
  }

  void _sdpParams(_Track t) {
    Uint8List? b64(String? s) {
      if (s == null || s.isEmpty) return null;
      try {
        return base64.decode(base64.normalize(s));
      } catch (_) {
        return null;
      }
    }

    if (codec == VideoCodec.h264) {
      for (final s in (t.fmtp['sprop-parameter-sets'] ?? '').split(',')) {
        final n = b64(s);
        if (n != null) params.take(n);
      }
    } else {
      for (final k in ['sprop-vps', 'sprop-sps', 'sprop-pps']) {
        final n = b64(t.fmtp[k]);
        if (n != null) params.take(n);
      }
    }
  }

  // ---------- recebimento ----------

  final List<Uint8List> _au = [];
  int? _auTs;
  int? _vBase, _aBase;
  int _vLast = 0, _vWrap = 0;
  int _aLast = 0, _aWrap = 0;
  final Stopwatch _clock = Stopwatch()..start();
  int? _vStartMs, _aStartMs;
  Uint8List? _fu;

  Future<void> _readLoop() async {
    try {
      while (!_closed) {
        final first = await _in.peek(1);
        if (first == null) break;
        if (first[0] != 0x24) {
          await _readResponse(); // resposta de keep-alive
          continue;
        }
        final h = await _in.read(4);
        if (h == null) break;
        final len = (h[2] << 8) | h[3];
        final pkt = await _in.read(len);
        if (pkt == null) break;
        final t = _channels[h[1]];
        if (t == null || pkt.length < 12) continue; // RTCP ou canal desconhecido
        _rtp(t, pkt);
      }
    } catch (e) {
      _finish('Erro recebendo o vídeo: $e');
      return;
    }
    _finish('A câmera encerrou a conexão.');
  }

  void _rtp(_Track t, Uint8List p) {
    final cc = p[0] & 0x0F;
    final ext = (p[0] & 0x10) != 0;
    final pad = (p[0] & 0x20) != 0;
    final marker = (p[1] & 0x80) != 0;
    final ts = (p[4] << 24) | (p[5] << 16) | (p[6] << 8) | p[7];
    var off = 12 + cc * 4;
    if (ext && off + 4 <= p.length) {
      off += 4 + (((p[off + 2] << 8) | p[off + 3]) * 4);
    }
    var end = p.length;
    if (pad && end > off) end -= p[end - 1];
    if (off >= end) return;
    final payload = Uint8List.sublistView(p, off, end);
    if (t.kind == 'video') {
      _videoPayload(payload, ts, marker);
    } else {
      _audioPayload(payload, ts, t.clock);
    }
  }

  int _unwrap(int ts, bool video) {
    if (video) {
      if (_vBase == null) {
        _vBase = ts;
        _vLast = ts;
      }
      if (ts < _vLast && _vLast - ts > 0x7FFFFFFF) _vWrap += 0x100000000;
      _vLast = ts;
      return ts + _vWrap - _vBase!;
    }
    if (_aBase == null) {
      _aBase = ts;
      _aLast = ts;
    }
    if (ts < _aLast && _aLast - ts > 0x7FFFFFFF) _aWrap += 0x100000000;
    _aLast = ts;
    return ts + _aWrap - _aBase!;
  }

  void _videoPayload(Uint8List p, int ts, bool marker) {
    if (_auTs != null && ts != _auTs) _flush();
    _auTs = ts;
    if (codec == VideoCodec.h264) {
      final type = p[0] & 0x1F;
      if (type >= 1 && type <= 23) {
        _au.add(Uint8List.fromList(p));
      } else if (type == 24) {
        var i = 1;
        while (i + 2 <= p.length) {
          final n = (p[i] << 8) | p[i + 1];
          i += 2;
          if (i + n > p.length) break;
          _au.add(Uint8List.fromList(Uint8List.sublistView(p, i, i + n)));
          i += n;
        }
      } else if (type == 28 && p.length > 2) {
        final s = (p[1] & 0x80) != 0, e = (p[1] & 0x40) != 0;
        if (s) {
          _fu = Uint8List.fromList([(p[0] & 0xE0) | (p[1] & 0x1F), ...p.sublist(2)]);
        } else if (_fu != null) {
          _fu = Uint8List.fromList([..._fu!, ...p.sublist(2)]);
        }
        if (e && _fu != null) {
          _au.add(_fu!);
          _fu = null;
        }
      }
    } else {
      if (p.length < 3) return;
      final type = (p[0] >> 1) & 0x3F;
      if (type == 48) {
        var i = 2;
        while (i + 2 <= p.length) {
          final n = (p[i] << 8) | p[i + 1];
          i += 2;
          if (i + n > p.length) break;
          _au.add(Uint8List.fromList(Uint8List.sublistView(p, i, i + n)));
          i += n;
        }
      } else if (type == 49) {
        final s = (p[2] & 0x80) != 0, e = (p[2] & 0x40) != 0;
        final fuType = p[2] & 0x3F;
        if (s) {
          _fu = Uint8List.fromList([(p[0] & 0x81) | (fuType << 1), p[1], ...p.sublist(3)]);
        } else if (_fu != null) {
          _fu = Uint8List.fromList([..._fu!, ...p.sublist(3)]);
        }
        if (e && _fu != null) {
          _au.add(_fu!);
          _fu = null;
        }
      } else {
        _au.add(Uint8List.fromList(p));
      }
    }
    if (marker) _flush();
  }

  void _flush() {
    if (_au.isEmpty || _auTs == null) {
      _au.clear();
      return;
    }
    final nals = List<Uint8List>.of(_au);
    _au.clear();
    var key = false;
    for (final n in nals) {
      final t = nalType(codec, n);
      if (isParamNal(codec, t)) params.take(n);
      if (isKeyNal(codec, t)) key = true;
    }
    final rel = _unwrap(_auTs!, true);
    _vStartMs ??= _clock.elapsedMilliseconds;
    final timeMs = _vStartMs! + rel ~/ 90;
    _auTs = null;
    if (!_video.isClosed) _video.add(VideoFrame(nals, timeMs, key));
  }

  void _audioPayload(Uint8List p, int ts, int clock) {
    final rel = _unwrap(ts, false);
    _aStartMs ??= _clock.elapsedMilliseconds;
    final timeMs = _aStartMs! + rel * 1000 ~/ clock;
    if (!_audio.isClosed) {
      _audio.add(AudioChunk(g711ToPcm(p, ulaw: _ulaw), timeMs, clock));
    }
  }

  // ---------- fim ----------

  void _finish(String reason) {
    if (!_done.isCompleted) _done.complete(reason);
    close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _keepAlive?.cancel();
    try {
      if (_session != null) {
        _socket?.write(_text('TEARDOWN', _base, const {}));
        await _socket?.flush().timeout(const Duration(seconds: 1));
      }
    } catch (_) {}
    await _sub?.cancel();
    _socket?.destroy();
    _in.close();
    if (!_done.isCompleted) _done.complete('Conexão encerrada.');
    await _video.close();
    await _audio.close();
  }
}

class _Response {
  final int status;
  final Map<String, String> headers;
  final List<String> allAuth;
  final String body;
  _Response(this.status, this.headers, this.allAuth, this.body);
}

/// Fila de bytes com leitura assíncrona de tamanho exato.
class _ByteQueue {
  Uint8List _buf = Uint8List(64 * 1024);
  int _start = 0, _end = 0;
  bool _closed = false;
  Completer<void>? _wait;

  int get _len => _end - _start;

  void add(Uint8List d) {
    if (_end + d.length > _buf.length) {
      final need = _len + d.length;
      if (need > _buf.length ~/ 2 || _start == 0) {
        var size = _buf.length;
        while (size < need * 2) {
          size *= 2;
        }
        final nb = Uint8List(size);
        nb.setRange(0, _len, _buf, _start);
        _buf = nb;
      } else {
        _buf.setRange(0, _len, _buf, _start);
      }
      _end = _len;
      _start = 0;
    }
    _buf.setRange(_end, _end + d.length, d);
    _end += d.length;
    _wake();
  }

  void close() {
    _closed = true;
    _wake();
  }

  void _wake() {
    final w = _wait;
    _wait = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<bool> _ensure(int n) async {
    while (_len < n) {
      if (_closed) return false;
      _wait ??= Completer<void>();
      await _wait!.future;
    }
    return true;
  }

  Future<Uint8List?> peek(int n) async {
    if (!await _ensure(n)) return null;
    return Uint8List.sublistView(_buf, _start, _start + n);
  }

  Future<Uint8List?> read(int n) async {
    if (!await _ensure(n)) return null;
    final out = Uint8List.fromList(Uint8List.sublistView(_buf, _start, _start + n));
    _start += n;
    return out;
  }

  /// Lê até "\r\n\r\n" (inclusive) e devolve o cabeçalho sem ele.
  Future<Uint8List?> readUntilCrlf2() async {
    var scanFrom = 0;
    while (true) {
      for (var i = _start + scanFrom; i + 3 < _end; i++) {
        if (_buf[i] == 13 && _buf[i + 1] == 10 && _buf[i + 2] == 13 && _buf[i + 3] == 10) {
          final out = Uint8List.fromList(Uint8List.sublistView(_buf, _start, i));
          _start = i + 4;
          return out;
        }
      }
      scanFrom = (_len - 3).clamp(0, 1 << 30);
      if (_len > 64 * 1024) return null; // não é RTSP
      if (_closed) return null;
      _wait ??= Completer<void>();
      await _wait!.future;
    }
  }
}
