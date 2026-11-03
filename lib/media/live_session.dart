// Sessão ao vivo: recebe a câmera pelo cliente RTSP próprio e entrega ao
// player como MKV por um servidor HTTP local (127.0.0.1). Também grava MP4.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'mkv_stream.dart';
import 'mp4_writer.dart';
import 'nal.dart';
import 'rtsp_client.dart';

class LiveSession {
  LiveSession({
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

  RtspClient? _rtsp;
  HttpServer? _server;
  MkvLiveMuxer? _mux;
  Uint8List? _header;
  final List<_Client> _clients = [];
  final List<StreamSubscription> _subs = [];
  final _ready = Completer<String>();
  Mp4Writer? _rec;
  Future<void> _recChain = Future.value();
  bool _closed = false;

  /// Endereço para o player abrir (fica pronto no primeiro quadro-chave).
  Future<String> get url => _ready.future;

  /// Motivo do fim da conexão com a câmera.
  Future<String> get done => _rtsp?.done ?? Future.value('Não conectado.');

  bool get recording => _rec != null;
  int get recordedMs => _rec?.durationMs ?? 0;
  VideoCodec? get codec => _rtsp?.codec;

  Future<void> start() async {
    // Evita erro "não tratado" se ninguém estiver esperando o endereço.
    _ready.future.then((_) {}, onError: (_) {});
    final rtsp = RtspClient(host: host, port: port, user: user, password: password, path: path);
    _rtsp = rtsp;
    await rtsp.start();

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_serve);

    _subs.add(rtsp.video.listen(_onVideo));
    _subs.add(rtsp.audio.listen(_onAudio));
    unawaited(rtsp.done.then((reason) {
      if (!_ready.isCompleted) _ready.completeError(RtspError(reason));
    }));
    // Se não chegar imagem em 15 s, desiste.
    Timer(const Duration(seconds: 15), () {
      if (!_ready.isCompleted) {
        _ready.completeError(RtspError('A câmera conectou mas não mandou imagem.'));
      }
    });
  }

  void _serve(HttpRequest req) {
    if (_header == null) {
      req.response.statusCode = 503;
      req.response.close();
      return;
    }
    final res = req.response;
    res.bufferOutput = false;
    res.headers.contentType = ContentType('video', 'x-matroska');
    res.headers.set('Cache-Control', 'no-cache');
    final ctl = StreamController<List<int>>();
    final c = _Client(ctl);
    _clients.add(c);
    ctl.add(_header!);
    res.addStream(ctl.stream).whenComplete(() {
      _clients.remove(c);
      res.close().catchError((_) {});
    }).catchError((_) {});
    req.response.done.catchError((_) {}).whenComplete(() {
      c.dead = true;
      _clients.remove(c);
    });
  }

  void _onVideo(VideoFrame f) {
    final rtsp = _rtsp!;
    if (_mux == null) {
      if (!f.key || !rtsp.params.ready) return;
      _mux = MkvLiveMuxer(rtsp.params, audioRate: rtsp.audioRate);
      _header = _mux!.header();
      if (!_ready.isCompleted) {
        _ready.complete('http://127.0.0.1:${_server!.port}/live.mkv');
      }
    }
    final bytes = _mux!.video(f);
    for (final c in List.of(_clients)) {
      if (c.dead) continue;
      if (!c.started) {
        if (!f.key) continue;
        c.started = true;
      }
      c.ctl.add(bytes);
    }
    final rec = _rec;
    if (rec != null) {
      // Escreve em ordem (uma escrita por vez).
      _recChain = _recChain.then((_) => rec.add(f)).catchError((_) {});
    }
  }

  void _onAudio(AudioChunk a) {
    final bytes = _mux?.audio(a);
    if (bytes == null) return;
    for (final c in _clients) {
      if (c.started && !c.dead) c.ctl.add(bytes);
    }
  }

  // ---------- gravação ----------

  Future<void> startRecording(File out) async {
    final rtsp = _rtsp;
    if (rtsp == null || _rec != null) return;
    final w = await Mp4Writer.create(out, rtsp.codec);
    w.takeParams([
      if (rtsp.params.vps != null) rtsp.params.vps!,
      if (rtsp.params.sps != null) rtsp.params.sps!,
      if (rtsp.params.pps != null) rtsp.params.pps!,
    ]);
    _rec = w;
  }

  /// Para e fecha o MP4. Devolve o arquivo, ou null se nada foi gravado.
  Future<File?> stopRecording() async {
    final w = _rec;
    _rec = null;
    if (w == null) return null;
    // Espera os quadros pendentes terminarem de ser escritos.
    await _recChain;
    return await w.finish() ? w.file : null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    if (_rec != null) await stopRecording();
    for (final s in _subs) {
      await s.cancel();
    }
    for (final c in _clients) {
      await c.ctl.close();
    }
    _clients.clear();
    await _server?.close(force: true);
    await _rtsp?.close();
  }
}

class _Client {
  _Client(this.ctl);
  final StreamController<List<int>> ctl;
  bool started = false;
  bool dead = false;
}
