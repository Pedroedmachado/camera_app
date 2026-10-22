import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'gallery_page.dart';
import 'settings_page.dart';
import 'storage.dart';

class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

class _LivePageState extends State<LivePage> {
  final Player _player = Player(
    configuration: const PlayerConfiguration(
      title: 'CamLivre',
      logLevel: MPVLogLevel.warn,
    ),
  );
  late final VideoController _controller = VideoController(_player);

  CameraConfig? _cfg;
  bool _hd = true;
  bool _muted = true;
  bool _connecting = false;
  bool _hasVideo = false;
  String? _error;
  bool _fullscreen = false;

  bool _recording = false;
  String? _recPath;
  DateTime? _recStart;
  Timer? _recTicker;

  Timer? _retry;
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted) {
        setState(() {
          _hasVideo = true;
          _connecting = false;
          _error = null;
        });
      }
    }));
    _subs.add(_player.stream.completed.listen((done) {
      // Stream caiu (Wi-Fi, câmera reiniciou...): tenta de novo.
      if (done) _scheduleRetry('Conexão encerrada pela câmera.');
    }));
    _loadAndConnect();
  }

  @override
  void dispose() {
    _retry?.cancel();
    _recTicker?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    if (_recording) _setProp('stream-record', '');
    _player.dispose();
    WakelockPlus.disable();
    _exitFullscreenSystemUi();
    super.dispose();
  }

  // ---------- conexão ----------

  Future<void> _setProp(String key, String value) async {
    // Acesso direto às propriedades do mpv (Android e Windows).
    final dynamic platform = _player.platform;
    try {
      await platform.setProperty(key, value);
    } catch (e) {
      debugPrint('mpv $key=$value falhou: $e');
    }
  }

  Future<void> _loadAndConnect() async {
    final cfg = await CameraConfig.load();
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _hd = cfg.hd;
    });
    if (cfg.isComplete) await _connect();
  }

  Future<void> _connect() async {
    final cfg = _cfg;
    if (cfg == null || !cfg.isComplete) return;
    _retry?.cancel();
    if (_recording) await _stopRecording();
    setState(() {
      _connecting = true;
      _hasVideo = false;
      _error = null;
    });
    // Baixa latência e RTSP por TCP (mais estável no Wi-Fi).
    await _setProp('demuxer-lavf-o', 'rtsp_transport=tcp,fflags=nobuffer');
    await _setProp('cache', 'no');
    await _setProp('video-latency-hacks', 'yes');
    await _setProp('network-timeout', '10');
    await _player.setVolume(_muted ? 0 : 100);
    await _player.open(Media(cfg.rtspUrl(hd: _hd)), play: true);
  }

  void _onError(String msg) {
    if (!mounted) return;
    _scheduleRetry(_friendlyError(msg));
  }

  void _scheduleRetry(String message) {
    if (!mounted) return;
    setState(() {
      _error = message;
      _connecting = false;
      _hasVideo = false;
    });
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 5), () {
      if (mounted && _cfg?.isComplete == true) _connect();
    });
  }

  String _friendlyError(String raw) {
    final m = raw.toLowerCase();
    if (m.contains('401') || m.contains('unauthorized')) {
      return 'Usuário ou senha errados. Confira em Configurações (a senha é a chave de acesso da câmera).';
    }
    if (m.contains('refused') || m.contains('timed out') || m.contains('timeout') ||
        m.contains('unreachable') || m.contains('no route')) {
      return 'Não achei a câmera nesse IP. Confira o IP e se você está no mesmo Wi-Fi.';
    }
    if (m.contains('404') || m.contains('not found')) {
      return 'A câmera respondeu, mas recusou o caminho do vídeo. Confira o canal.';
    }
    return 'Falha ao abrir o vídeo: $raw';
  }

  // ---------- ações ----------

  Future<void> _toggleAudio() async {
    setState(() => _muted = !_muted);
    await _player.setVolume(_muted ? 0 : 100);
  }

  Future<void> _toggleQuality() async {
    setState(() => _hd = !_hd);
    await _connect();
  }

  Future<void> _snapshot() async {
    if (!_hasVideo) {
      _toast('Sem imagem para fotografar.');
      return;
    }
    final bytes = await _player.screenshot(format: 'image/jpeg');
    if (bytes == null) {
      _toast('Não consegui capturar a foto.');
      return;
    }
    final dir = await Storage.photos();
    final file = File(p.join(dir.path, 'foto_${Storage.stamp()}.jpg'));
    await file.writeAsBytes(bytes);
    _toast('Foto salva.', openGallery: true);
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      await _stopRecording();
      _toast('Vídeo salvo.', openGallery: true);
      return;
    }
    if (!_hasVideo) {
      _toast('Sem imagem para gravar.');
      return;
    }
    final dir = await Storage.videos();
    final path = p.join(dir.path, 'video_${Storage.stamp()}.mkv');
    // O mpv copia o stream original para o arquivo, sem recodificar.
    await _setProp('stream-record', path);
    setState(() {
      _recording = true;
      _recPath = path;
      _recStart = DateTime.now();
    });
    _recTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _stopRecording() async {
    await _setProp('stream-record', '');
    _recTicker?.cancel();
    _recTicker = null;
    if (!mounted) return;
    setState(() {
      _recording = false;
      _recStart = null;
    });
    final path = _recPath;
    _recPath = null;
    if (path != null) {
      final f = File(path);
      if (await f.exists() && await f.length() < 1024) await f.delete();
    }
  }

  Future<void> _toggleFullscreen() async {
    setState(() => _fullscreen = !_fullscreen);
    if (Platform.isAndroid) {
      if (_fullscreen) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        await _exitFullscreenSystemUi();
      }
    }
  }

  Future<void> _exitFullscreenSystemUi() async {
    if (!Platform.isAndroid) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
  }

  Future<void> _openSettings() async {
    if (_recording) await _stopRecording();
    if (!mounted) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const SettingsPage()),
    );
    if (changed == true) {
      await _player.stop();
      await _loadAndConnect();
    }
  }

  Future<void> _openGallery() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const GalleryPage()),
    );
  }

  void _toast(String msg, {bool openGallery = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(seconds: 2),
        action: openGallery
            ? SnackBarAction(label: 'Ver', onPressed: _openGallery)
            : null,
      ));
  }

  String _recLabel() {
    final s = _recStart;
    if (s == null) return '';
    final d = DateTime.now().difference(s);
    final mm = d.inMinutes.toString().padLeft(2, '0');
    final ss = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$mm:$ss';
  }

  // ---------- interface ----------

  @override
  Widget build(BuildContext context) {
    final cfg = _cfg;
    if (cfg == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!cfg.isComplete) return _setupPrompt();
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(child: _videoArea()),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              color: Colors.black45,
              child: SafeArea(top: false, child: _controls()),
            ),
          ),
        ]),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(cfg.name),
        actions: [
          IconButton(
            tooltip: 'Galeria',
            icon: const Icon(Icons.photo_library_outlined),
            onPressed: _openGallery,
          ),
          IconButton(
            tooltip: 'Configurações',
            icon: const Icon(Icons.settings_outlined),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(color: Colors.black, child: _videoArea()),
        ),
        _controls(),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            '${_hd ? 'HD (principal)' : 'SD (leve)'} · ${cfg.host}:${cfg.port}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ]),
    );
  }

  Widget _videoArea() {
    return Stack(fit: StackFit.expand, children: [
      Video(
        controller: _controller,
        controls: NoVideoControls,
        fit: BoxFit.contain,
      ),
      if (_connecting && !_hasVideo)
        const Center(child: CircularProgressIndicator()),
      if (_error != null && !_hasVideo)
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.videocam_off_outlined, size: 40),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              const Text('Tentando de novo em 5 s…',
                  style: TextStyle(color: Colors.white54)),
              TextButton(onPressed: _connect, child: const Text('Tentar agora')),
            ]),
          ),
        ),
      if (_recording)
        Positioned(
          top: 12,
          left: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.red.shade700,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text('● REC ${_recLabel()}',
                style: const TextStyle(fontWeight: FontWeight.bold)),
          ),
        ),
    ]);
  }

  Widget _controls() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _btn(_muted ? Icons.volume_off : Icons.volume_up,
              _muted ? 'Som' : 'Mudo', _toggleAudio),
          _btn(Icons.photo_camera_outlined, 'Foto', _snapshot),
          _btn(
            _recording ? Icons.stop_circle : Icons.fiber_manual_record,
            _recording ? 'Parar' : 'Gravar',
            _toggleRecording,
            color: _recording ? Colors.red : null,
          ),
          _btn(_hd ? Icons.hd : Icons.sd, _hd ? 'HD' : 'SD', _toggleQuality),
          _btn(_fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
              'Tela', _toggleFullscreen),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, String label, VoidCallback onTap, {Color? color}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 28, color: color),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12)),
        ]),
      ),
    );
  }

  Widget _setupPrompt() {
    return Scaffold(
      appBar: AppBar(title: const Text('CamLivre')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.videocam_outlined, size: 56),
            const SizedBox(height: 16),
            const Text(
              'Configure a câmera para começar.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            const Text(
              'Você vai precisar do IP da câmera e da chave de acesso.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white70),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Configurar'),
            ),
          ]),
        ),
      ),
    );
  }
}
