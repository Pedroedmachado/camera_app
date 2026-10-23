import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'dahua_http.dart';
import 'sd_api.dart';
import 'player_util.dart';
import 'rec_saver.dart';
import 'storage.dart';

/// Assiste uma gravação do cartão SD (stream de reprodução RTSP da câmera).
class PlaybackPage extends StatefulWidget {
  const PlaybackPage({
    super.key,
    required this.cfg,
    required this.start,
    required this.end,
    this.recording,
    this.api,
  });

  final CameraConfig cfg;
  final DateTime start;
  final DateTime end;
  final Recording? recording; // presente quando veio da lista
  final SdApi? api; // permite baixar o arquivo original

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

  @override
  void initState() {
    super.initState();
    _subs.add(_player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted) {
        setState(() {
          _hasVideo = true;
          _error = null;
        });
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
    _subs.add(_player.stream.playing.listen((v) {
      if (mounted) setState(() => _playing = v);
    }));
    _open();
  }

  Future<void> _open() async {
    await prepareRtsp(_player, await savedTransport());
    await _player.setVolume(_muted ? 0 : 100);
    await _player.open(
      Media(widget.cfg.playbackUrl(widget.start, widget.end)),
      play: true,
    );
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    _dlCancel = true;
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
    final bytes = await _player.screenshot(format: 'image/jpeg');
    if (bytes == null) {
      _toast('Sem imagem para fotografar.');
      return;
    }
    final dir = await Storage.photos();
    await File(p.join(dir.path, 'foto_cartao_${Storage.stamp()}.jpg'))
        .writeAsBytes(bytes);
    _toast('Foto salva na Galeria.');
  }

  /// Grava o que está passando na tela para um .mkv (funciona sem a API web).
  Future<void> _toggleRecord() async {
    if (_recording) {
      await mpvSet(_player, 'stream-record', '');
      setState(() => _recording = false);
      final path = _recPath;
      if (path != null) {
        final f = File(path);
        if (await f.exists() && await f.length() < 1024) await f.delete();
      }
      _toast('Trecho salvo na Galeria.');
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

  /// Baixa a gravação inteira e converte para vídeo comum (.mkv).
  Future<void> _download() async {
    final rec = widget.recording;
    final api = widget.api;
    if (rec == null || api == null) return;
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

  @override
  Widget build(BuildContext context) {
    final total = widget.end.difference(widget.start);
    final shown = widget.start.add(_pos);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: Text(
          '${dmy(widget.start)}  ${hms(widget.start)}–${hms(widget.end)}',
          style: const TextStyle(fontSize: 15),
        ),
      ),
      body: Column(children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(fit: StackFit.expand, children: [
            Video(controller: _controller, controls: NoVideoControls),
            if (!_hasVideo && _error == null)
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
                      label: const Text('Salvar gravação como vídeo (.mkv)'),
                    ),
                  ),
          ),
        const Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            '“Salvar como vídeo” baixa a gravação inteira do cartão e converte para .mkv, '
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
