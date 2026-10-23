import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'config.dart';
import 'gallery_page.dart';
import 'rtsp_probe.dart';
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

  // Modos de transporte RTSP testados em ordem; o que funcionar fica salvo.
  static const _transports = ['tcp', 'udp', 'http'];
  List<String> _order = List.of(_transports);
  int _attempt = 0;
  bool _failureHandled = false;
  bool _diagnosing = false;
  String? _diagnosis;
  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    _subs.add(_player.stream.error.listen(_onError));
    _subs.add(_player.stream.log.listen((l) {
      final lvl = l.level.toLowerCase();
      if (lvl == 'warn' || lvl == 'error' || lvl == 'fatal') {
        _log.add('[${l.prefix}] ${l.text.trim()}');
        if (_log.length > 8) _log.removeAt(0);
      }
    }));
    _subs.add(_player.stream.width.listen((w) {
      if ((w ?? 0) > 0 && mounted) {
        _retry?.cancel();
        _saveTransport(_order[_attempt]);
        setState(() {
          _hasVideo = true;
          _connecting = false;
          _error = null;
          _diagnosis = null;
        });
      }
    }));
    _subs.add(_player.stream.completed.listen((done) {
      // Só conta como queda se o vídeo já estava passando.
      if (done && _hasVideo) {
        setState(() => _hasVideo = false);
        _connect();
      }
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

  Future<void> _saveTransport(String t) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('transport', t);
  }

  Future<void> _loadAndConnect() async {
    final cfg = await CameraConfig.load();
    final sp = await SharedPreferences.getInstance();
    final saved = sp.getString('transport');
    if (!mounted) return;
    setState(() {
      _cfg = cfg;
      _hd = cfg.hd;
      _order = List.of(_transports);
      if (saved != null && _order.remove(saved)) _order.insert(0, saved);
    });
    if (cfg.isComplete) await _connect();
  }

  /// [fresh] = começa a sequência de modos do zero.
  Future<void> _connect({bool fresh = true}) async {
    final cfg = _cfg;
    if (cfg == null || !cfg.isComplete) return;
    _retry?.cancel();
    if (_recording) await _stopRecording();
    if (fresh) _attempt = 0;
    _failureHandled = false;
    _log.clear();
    setState(() {
      _connecting = true;
      _hasVideo = false;
      _error = null;
      if (fresh) _diagnosis = null;
    });
    await _setProp('rtsp-transport', _order[_attempt]);
    await _setProp('cache', 'no');
    await _setProp('video-latency-hacks', 'yes');
    await _setProp('network-timeout', '10');
    await _player.setVolume(_muted ? 0 : 100);
    await _player.open(Media(cfg.rtspUrl(hd: _hd)), play: true);
  }

  void _onError(String msg) {
    if (!mounted || _failureHandled || _hasVideo) return;
    _failureHandled = true;
    if (_attempt < _order.length - 1) {
      // Tenta o próximo modo de transporte na hora.
      _attempt++;
      _connect(fresh: false);
      return;
    }
    setState(() {
      _error = _friendlyError(msg);
      _connecting = false;
    });
    _diagnose();
    _retry = Timer(const Duration(seconds: 15), () {
      if (mounted && _cfg?.isComplete == true && !_hasVideo) _connect();
    });
  }

  /// Testa a câmera direto (sem o player) para dizer a causa real.
  Future<void> _diagnose() async {
    final cfg = _cfg;
    if (cfg == null || _diagnosing) return;
    setState(() => _diagnosing = true);
    final r = await RtspProbe.run(
      host: cfg.host.trim(),
      port: cfg.port,
      user: cfg.user,
      password: cfg.password,
      path: cfg.rtspPath(hd: _hd),
    );
    if (!mounted) return;
    setState(() {
      _diagnosing = false;
      _diagnosis = r.ok
          ? '${r.message}\nO problema está no player do app — me mande este print.'
          : r.message;
    });
  }

  String _friendlyError(String raw) {
    final m = '$raw ${_log.join(' ')}'.toLowerCase();
    if (m.contains('401') || m.contains('unauthorized')) {
      return 'Usuário ou senha errados.';
    }
    if (m.contains('refused') || m.contains('timed out') || m.contains('timeout') ||
        m.contains('unreachable') || m.contains('no route')) {
      return 'Não achei a câmera nesse IP.';
    }
    if (m.contains('404') || m.contains('not found')) {
      return 'A câmera recusou o caminho do vídeo.';
    }
    return 'Falha ao abrir o vídeo (testei TCP, UDP e HTTP).';
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
      if (_connecting && !_hasVideo && _error == null)
        Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 12),
            Text('Conectando (${_order[_attempt].toUpperCase()})…',
                style: const TextStyle(color: Colors.white70)),
          ]),
        ),
      if (_error != null && !_hasVideo)
        SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(children: [
            const Icon(Icons.videocam_off_outlined, size: 36),
            const SizedBox(height: 8),
            Text(_error!, textAlign: TextAlign.center),
            const SizedBox(height: 10),
            if (_diagnosing)
              const Text('Testando a câmera direto…',
                  style: TextStyle(color: Colors.white54))
            else if (_diagnosis != null)
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text('Diagnóstico: $_diagnosis',
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.amberAccent)),
              ),
            if (_log.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(_log.join('\n'),
                  style: const TextStyle(
                      fontSize: 10, color: Colors.white38, fontFamily: 'monospace')),
            ],
            TextButton(onPressed: _connect, child: const Text('Tentar agora')),
          ]),
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
