import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'config.dart';
import 'dahua_http.dart';
import 'sd_api.dart';

/// Aplica o giro/espelho escolhido "só no app" a um vídeo na tela.
Widget orientVideo(Widget video, {required int rotation, required bool mirror}) {
  Widget w = RotatedBox(quarterTurns: rotation % 4, child: video);
  if (mirror) w = Transform.flip(flipX: true, child: w);
  return w;
}

/// Gira a foto (JPEG) do mesmo jeito que a tela, para salvar certinha.
Future<Uint8List> orientJpeg(Uint8List bytes, int rotation, bool mirror) async {
  if (rotation % 4 == 0 && !mirror) return bytes;
  return compute(_orient, [bytes, rotation % 4, mirror]);
}

Uint8List _orient(List<Object> a) {
  final bytes = a[0] as Uint8List;
  final rot = a[1] as int;
  final mirror = a[2] as bool;
  var im = img.decodeImage(bytes);
  if (im == null) return bytes;
  if (rot != 0) im = img.copyRotate(im, angle: rot * 90);
  if (mirror) im = img.flipHorizontal(im);
  return Uint8List.fromList(img.encodeJpg(im, quality: 92));
}

/// Estado de inversão gravado na própria câmera.
class CameraFlipState {
  final String configName;
  final List<dynamic> table;
  final bool flip;
  final bool mirror;
  CameraFlipState(this.configName, this.table, this.flip, this.mirror);
}

/// Liga/desliga a inversão da imagem direto na câmera (config Dahua).
/// Isso corrige também as gravações do cartão e os vídeos salvos.
class CameraFlip {
  CameraFlip(CameraConfig cfg)
      : _api = RpcSdApi(DahuaHttp(
          host: cfg.host.trim(),
          port: cfg.httpPort,
          user: cfg.user,
          password: cfg.password,
        )),
        _channel = cfg.channel - 1;

  final RpcSdApi _api;
  final int _channel;

  static const _names = ['VideoImageControl', 'VideoInOptions'];

  Future<CameraFlipState> read() async {
    final errors = <String>[];
    for (final name in _names) {
      try {
        final r = await _api.call('configManager.getConfig', params: {'name': name});
        final p = r['params'];
        final table = p is Map ? p['table'] : null;
        final list = table is List ? table : (table is Map ? [table] : null);
        if (list == null || list.isEmpty) continue;
        final idx = _channel.clamp(0, list.length - 1);
        final ch = list[idx];
        if (ch is! Map || !ch.containsKey('Flip')) continue;
        return CameraFlipState(
            name, list, ch['Flip'] == true, ch['Mirror'] == true);
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    throw HttpUnavailable(errors.isEmpty
        ? 'A câmera não informou a opção de inverter imagem.'
        : errors.join('\n'));
  }

  Future<void> write(CameraFlipState st, {required bool flip, required bool mirror}) async {
    final list = [for (final x in st.table) x is Map ? Map<String, dynamic>.from(x) : x];
    final idx = _channel.clamp(0, list.length - 1);
    final ch = list[idx] as Map<String, dynamic>;
    ch['Flip'] = flip;
    if (ch.containsKey('Mirror')) ch['Mirror'] = mirror;
    final r = await _api.call('configManager.setConfig',
        params: {'name': st.configName, 'table': list, 'options': []});
    if (r['result'] != true) {
      throw HttpUnavailable('A câmera não aceitou a mudança (${r['error'] ?? 'sem detalhe'}).');
    }
  }
}

/// Painel de orientação: na câmera (corrige tudo) ou só na tela do app.
Future<void> showOrientationSheet(
  BuildContext context,
  CameraConfig cfg, {
  required VoidCallback onAppChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _OrientationSheet(cfg: cfg, onAppChanged: onAppChanged),
  );
}

class _OrientationSheet extends StatefulWidget {
  const _OrientationSheet({required this.cfg, required this.onAppChanged});
  final CameraConfig cfg;
  final VoidCallback onAppChanged;

  @override
  State<_OrientationSheet> createState() => _OrientationSheetState();
}

class _OrientationSheetState extends State<_OrientationSheet> {
  late final CameraFlip _flip = CameraFlip(widget.cfg);
  CameraFlipState? _state;
  String? _camError;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _camError = null;
    });
    try {
      final s = await _flip.read();
      if (mounted) setState(() => _state = s);
    } catch (e) {
      if (mounted) setState(() => _camError = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setCamera({required bool flip, required bool mirror}) async {
    final st = _state;
    if (st == null) return;
    setState(() => _busy = true);
    try {
      await _flip.write(st, flip: flip, mirror: mirror);
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Pronto. A imagem da câmera muda em alguns segundos.')));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _camError = e.toString();
        });
      }
    }
  }

  Future<void> _setApp({int? rotation, bool? mirror}) async {
    final cfg = widget.cfg;
    if (rotation != null) cfg.rotation = rotation;
    if (mirror != null) cfg.mirror = mirror;
    await cfg.save();
    widget.onAppChanged();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cfg = widget.cfg;
    final st = _state;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Na câmera (recomendado)',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Corrige tudo: ao vivo, cartão SD, gravações e vídeos salvos.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 8),
          if (_busy)
            const Padding(
              padding: EdgeInsets.all(12),
              child: LinearProgressIndicator(),
            )
          else if (st != null) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.screen_rotation_alt),
              title: const Text('Câmera de ponta-cabeça (girar 180°)'),
              value: st.flip,
              onChanged: (v) => _setCamera(flip: v, mirror: st.mirror),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              secondary: const Icon(Icons.flip),
              title: const Text('Espelhar'),
              value: st.mirror,
              onChanged: (v) => _setCamera(flip: st.flip, mirror: v),
            ),
          ] else
            Text(
              'Não deu para mudar na câmera: ${_camError ?? ''}\n'
              'Use a opção abaixo (só no app).',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
            ),
          const Divider(height: 28),
          const Text('Só na tela do app',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Gira a imagem aqui e nas fotos. Não muda as gravações da câmera.',
            style: TextStyle(color: Colors.white60, fontSize: 13),
          ),
          const SizedBox(height: 10),
          Wrap(spacing: 8, children: [
            for (final r in const [0, 1, 2, 3])
              ChoiceChip(
                label: Text('${r * 90}°'),
                selected: cfg.rotation % 4 == r,
                onSelected: (_) => _setApp(rotation: r),
              ),
          ]),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Espelhar no app'),
            value: cfg.mirror,
            onChanged: (v) => _setApp(mirror: v),
          ),
          const Text(
            'Dica: use só um dos dois. Se inverter na câmera, deixe o app em 0°.',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
        ]),
      ),
    );
  }
}
