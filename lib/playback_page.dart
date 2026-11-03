import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:gal/gal.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'config.dart';
import 'converter.dart';
import 'dahua_http.dart';
import 'sd_api.dart';
import 'orientation.dart';
import 'player_util.dart';
import 'rec_saver.dart';
import 'storage.dart';

/// O que fazer sozinho assim que o vídeo abrir.
enum PlaybackAction { none, snapshot, record }

/// Gravações já baixadas nesta sessão (caminho no cartão → MP4 local).
final Map<String, File> _localCache = {};

/// Assiste uma gravação do cartão SD. Com a lista do cartão, baixa o arquivo e
/// toca localmente (permite avançar/voltar); sem ela, tenta o RTSP da câmera.
class PlaybackPage extends StatefulWidget {
  const PlaybackPage({
    super.key,
    required this.cfg,
    required this.start,
    required this.end,
    this.recording,
    this.api,
    this.autoAction = PlaybackAction.none,
  });

  final CameraConfig cfg;
  final DateTime start;
  final DateTime end;
  final Recording? recording; // presente quando veio da lista
  final SdApi? api; // permite baixar o arquivo original
  final PlaybackAction autoAction;

  @override
  State<PlaybackPage> createState() => _PlaybackPageState();
}

class _PlaybackPageState extends State<PlaybackPage> {
  final Player _player = Player(
    configuration: const PlayerConfiguration(logLevel: MPVLogLevel.warn),
  );
  late final VideoController _controller = VideoController(_player);
  final List<StreamSubscription> _subs = [];

  bool _hasVideo = false;
  String? _error;
  bool _playing = true;
  bool _muted = false;
  Duration _pos = Duration.zero;

  bool _recording = false;
  String? _recPath;

  bool _downloading = false;
  double _dlProgress = 0;
  bool _dlCancel = false;
  String _dlStatus = '';

  bool _fileMode = false; // tocando o arquivo baixado do cartão
  String? _loadStatus; // "Baixando…" enquanto prepara
  double _loadProgress = 0;
  File? _localMp4;
  bool _disposed = false;
  Duration _fileDuration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted) {
        final first = !_hasVideo;
        setState(() {
          _hasVideo = true;
          _error = null;
        });
        if (first && !_fileMode) _runAutoAction();
      }
    }));
    _subs.add(_player.stream.error.listen((e) {
      if (mounted && !_hasVideo) {
        setState(() => _error =
            'Não consegui abrir essa gravação. Pode não existir vídeo nesse horário.\n($e)');
      }
    }));
    _subs.add(_player.stream.position.listen((d) {
      if (mounted) setState(() => _pos = d);
    }));
    _subs.add(_player.stream.duration.listen((d) {
      if (mounted && d > Duration.zero) setState(() => _fileDuration = d);
    }));
    _subs.add(_player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _open();
  }

  bool _autoDone = false;

  Future<void> _runAutoAction() async {
    if (_autoDone) return;
    _autoDone = true;
    switch (widget.autoAction) {
      case PlaybackAction.none:
        return;
      case PlaybackAction.snapshot:
        // Espera a imagem firmar (o primeiro quadro pode vir borrado).
        await Future.delayed(const Duration(milliseconds: 1500));
        if (!mounted) return;
        await _player.pause();
        await _snapshot();
      case PlaybackAction.record:
        await _toggleRecord();
        _toast('Gravando a partir de ${hms(widget.start)}. Toque em Parar quando quiser.');
    }
  }

  Future<void> _open() async {
    final rec = widget.recording;
    final api = widget.api;
    if (rec != null && api != null) {
      try {
        await _openFile(rec, api);
        return;
      } catch (e) {
        if (_disposed || !mounted) return;
        setState(() {
          _fileMode = false;
          _loadStatus = null;
        });
        _toast('Não deu para baixar a gravação ($e). Tentando pela câmera…');
      }
    }
    await _openRtsp();
  }

  Future<void> _openRtsp() async {
    await prepareRtsp(_player, await savedTransport());
    await _player.setVolume(_muted ? 0 : 100);
    await _player.open(
      Media(widget.cfg.playbackUrl(widget.start, widget.end)),
      play: true,
    );
  }

  /// Baixa a gravação do cartão, converte para MP4 e toca o arquivo.
  Future<void> _openFile(Recording rec, SdApi api) async {
    setState(() {
      _fileMode = true;
      _loadStatus = 'Baixando a gravação do cartão…';
      _loadProgress = 0;
    });
    var mp4 = _localCache[rec.filePath];
    if (mp4 == null || !await mp4.exists()) {
      final tmp = await getTemporaryDirectory();
      final id = DateTime.now().microsecondsSinceEpoch;
      final dav = File(p.join(tmp.path, 'pb_$id.dav'));
      final out = File(p.join(tmp.path, 'pb_$id.mp4'));
      try {
        await api.download(rec, dav,
            cancelled: () => _disposed,
            onProgress: (r, t) {
              if (mounted && t > 0) setState(() => _loadProgress = r / t);
            });
        if (_disposed) return;
        if (mounted) {
          setState(() {
            _loadStatus = 'Preparando o vídeo…';
            _loadProgress = 0;
          });
        }
        await VideoConverter.toMp4(dav, out, duration: rec.duration);
      } finally {
        if (await dav.exists()) await dav.delete();
      }
      mp4 = out;
      _localCache[rec.filePath] = out;
    }
    if (_disposed || !mounted) return;
    _localMp4 = mp4;
    setState(() => _loadStatus = null);
    await _player.setVolume(_muted ? 0 : 100);
    await _player.open(Media(mp4.path), play: false);

    // Vai direto ao momento escolhido na linha do tempo.
    final offset = widget.start.difference(rec.start);
    if (offset > const Duration(seconds: 1)) {
      try {
        await _player.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 8));
      } catch (_) {}
      await _player.seek(offset);
    }
    await _player.play();
    await _runAutoAction();
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _dlCancel = true;
    _disposed = true;
    if (_recording) mpvSet(_player, 'stream-record', '');
    _player.dispose();
    super.dispose();
  }

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m)));
  }

  Future<void> _snapshot() async {
    final raw = await _player.screenshot(format: 'image/jpeg');
    final bytes = raw == null
        ? null
        : await orientJpeg(raw, widget.cfg.rotation, widget.cfg.mirror,
            stamp: widget.cfg.appClock ? clockText(_shownTime()) : null);
    if (bytes == null) {
      _toast('Sem imagem para fotografar.');
      return;
    }
    final dir = await Storage.photos();
    await File(p.join(dir.path, 'foto_cartao_${Storage.stamp()}.jpg'))
        .writeAsBytes(bytes);
    _toast('Foto salva na Galeria.');
  }

  /// Grava o que está passando na tela (vira MP4 no final; funciona sem a API web).
  Future<void> _toggleRecord() async {
    if (_recording) {
      await mpvSet(_player, 'stream-record', '');
      setState(() => _recording = false);
      final path = _recPath;
      _recPath = null;
      if (path != null) {
        _toast('Salvando em MP4…');
        final out = await finishAppRecording(path);
        if (out != null) _toast('Trecho salvo na Galeria (${p.extension(out.path)}).');
      }
      return;
    }
    if (!_hasVideo) {
      _toast('Espere o vídeo abrir.');
      return;
    }
    final dir = await Storage.videos();
    _recPath = p.join(dir.path, 'cartao_${Storage.stamp()}.mkv');
    await mpvSet(_player, 'stream-record', _recPath!);
    setState(() => _recording = true);
  }

  /// Baixa a gravação inteira e converte para MP4.
  Future<void> _download() async {
    final rec = widget.recording;
    final api = widget.api;
    if (rec == null || api == null) return;
    final local = _localMp4;
    if (local != null && await local.exists()) {
      // Já está baixado: só copia para a Galeria.
      final dir = await Storage.videos();
      final out = File(p.join(dir.path, recordingFileName(rec, 'mp4')));
      await local.copy(out.path);
      if (Platform.isAndroid) {
        try {
          if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
          await Gal.putVideo(out.path, album: 'CamLivre');
        } catch (_) {}
      }
      _toast('Vídeo salvo: ${p.basename(out.path)}'
          '${Platform.isAndroid ? ' (também na galeria do celular)' : ''}.');
      return;
    }
    setState(() {
      _downloading = true;
      _dlProgress = 0;
      _dlStatus = 'Baixando do cartão…';
      _dlCancel = false;
    });
    try {
      final out = await saveRecordingAsVideo(api, rec,
          cancelled: () => _dlCancel,
          onStatus: (st, prog) {
            if (mounted) {
              setState(() {
                _dlStatus = st;
                _dlProgress = prog ?? 0;
              });
            }
          });
      _toast('Vídeo salvo: ${p.basename(out.path)}'
          '${Platform.isAndroid ? ' (também na galeria do celular)' : ''}.');
    } catch (e) {
      _toast('$e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  /// Hora real do quadro que está na tela.
  DateTime _shownTime() {
    final rec = widget.recording;
    final base = _fileMode && rec != null ? rec.start : widget.start;
    return base.add(_pos);
  }

  @override
  Widget build(BuildContext context) {
    final rec = widget.recording;
    final base = _fileMode && rec != null ? rec.start : widget.start;
    final total = _fileMode
        ? (_fileDuration > Duration.zero ? _fileDuration : (rec?.duration ?? Duration.zero))
        : widget.end.difference(widget.start);
    final shown = base.add(_pos);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          _fileMode && rec != null
              ? '${dmy(rec.start)}  ${hms(rec.start)}–${hms(rec.end)}'
              : '${dmy(widget.start)}  ${hms(widget.start)}–${hms(widget.end)}',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Column(children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(fit: StackFit.expand, children: [
            orientVideo(
              Video(controller: _controller, controls: NoVideoControls),
              rotation: widget.cfg.rotation,
              mirror: widget.cfg.mirror,
            ),
            if (widget.cfg.appClock && _hasVideo) ClockOverlay(time: shown),
            if (_loadStatus != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    CircularProgressIndicator(
                        value: _loadProgress > 0 ? _loadProgress : null),
                    const SizedBox(height: 12),
                    Text(
                      _loadProgress > 0
                          ? '$_loadStatus ${(_loadProgress * 100).toStringAsFixed(0)}%'
                          : _loadStatus!,
                      textAlign: TextAlign.center,
                    ),
                  ]),
                ),
              )
            else if (!_hasVideo && _error == null)
              const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(_error!, textAlign: TextAlign.center),
                ),
              ),
            if (_recording)
              Positioned(
                top: 10,
                left: 10,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  color: Colors.red.shade700,
                  child: const Text('● GRAVANDO TRECHO'),
                ),
              ),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Row(children: [
            Text(hms(shown)),
            const Spacer(),
            Text('${formatDuration(_pos)} de ${formatDuration(total)}',
                style: const TextStyle(color: Colors.white60)),
          ]),
        ),
        if (_fileMode && total > Duration.zero)
          Slider(
            value: _pos.inMilliseconds.clamp(0, total.inMilliseconds).toDouble(),
            max: total.inMilliseconds.toDouble(),
            onChanged: (v) => _player.seek(Duration(milliseconds: v.round())),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: LinearProgressIndicator(
              value: total.inMilliseconds == 0
                  ? 0
                  : (_pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0),
            ),
          ),
        const SizedBox(height: 8),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          _btn(_playing ? Icons.pause : Icons.play_arrow,
              _playing ? 'Pausar' : 'Tocar', () => _player.playOrPause()),
          _btn(_muted ? Icons.volume_off : Icons.volume_up, 'Som', () async {
            setState(() => _muted = !_muted);
            await _player.setVolume(_muted ? 0 : 100);
          }),
          _btn(Icons.photo_camera_outlined, 'Foto', _snapshot),
          _btn(_recording ? Icons.stop_circle : Icons.fiber_manual_record,
              _recording ? 'Parar' : 'Gravar', _toggleRecord,
              color: _recording ? Colors.red : null),
        ]),
        const SizedBox(height: 12),
        if (widget.recording != null && widget.api != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _downloading
                ? Column(children: [
                    LinearProgressIndicator(value: _dlProgress == 0 ? null : _dlProgress),
                    const SizedBox(height: 6),
                    Row(children: [
                      Text(_dlProgress > 0
                          ? '$_dlStatus ${(_dlProgress * 100).toStringAsFixed(0)}%'
                          : _dlStatus),
                      const Spacer(),
                      TextButton(
                          onPressed: () => _dlCancel = true,
                          child: const Text('Cancelar')),
                    ]),
                  ])
                : SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _download,
                      icon: const Icon(Icons.download),
                      label: const Text('Salvar gravação como vídeo (MP4)'),
                    ),
                  ),
          ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '“Salvar como vídeo” baixa a gravação inteira do cartão e converte para MP4, '
            'sem perder qualidade. “Gravar” salva só o que passar na tela.',
            style: TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ),
      ]),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 28, color: color),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }
}
