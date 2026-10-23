import 'package:flutter/material.dart';

import 'config.dart';
import 'dahua_http.dart';
import 'sd_api.dart';

enum RecMode { continuous, motion, off }

class RecordSettings {
  RecMode mode;
  int latch; // segundos gravando depois que o movimento para
  bool motionDetect; // detecção de movimento ligada
  RecordSettings(this.mode, this.latch, this.motionDetect);
}

/// Lê e muda o modo de gravação do cartão direto na câmera (configs Dahua
/// "Record", "RecordMode" e "MotionDetect").
class RecordModeControl {
  RecordModeControl(CameraConfig cfg)
      : _api = RpcSdApi(DahuaHttp(
          host: cfg.host.trim(),
          port: cfg.httpPort,
          user: cfg.user,
          password: cfg.password,
        )),
        _ch = cfg.channel - 1;

  final RpcSdApi _api;
  final int _ch;

  // Bits da agenda: 1 = contínua, 2 = movimento, 4 = alarme.
  static const _maskContinuous = 7;
  static const _maskMotion = 6;

  Future<List<dynamic>?> _table(String name) async {
    try {
      final r = await _api.call('configManager.getConfig', params: {'name': name});
      final p = r['params'];
      final t = p is Map ? p['table'] : null;
      if (t is List) return [for (final x in t) x is Map ? Map<String, dynamic>.from(x) : x];
      if (t is Map) return [Map<String, dynamic>.from(t)];
    } on RpcError {
      return null;
    }
    return null;
  }

  Future<void> _set(String name, List<dynamic> table) async {
    final r = await _api.call('configManager.setConfig',
        params: {'name': name, 'table': table, 'options': []});
    if (r['result'] != true) {
      throw HttpUnavailable('A câmera recusou "$name" (${r['error'] ?? 'sem detalhe'}).');
    }
  }

  Map<String, dynamic>? _row(List<dynamic>? t) {
    if (t == null || t.isEmpty) return null;
    final x = t[_ch.clamp(0, t.length - 1)];
    return x is Map<String, dynamic> ? x : null;
  }

  Future<RecordSettings> read() async {
    await _api.connect();
    final rec = _row(await _table('Record'));
    final mode = _row(await _table('RecordMode'));
    final md = _row(await _table('MotionDetect'));
    if (rec == null && md == null) {
      throw HttpUnavailable('A câmera não informou as configurações de gravação.');
    }

    var mask = 0;
    final ts = rec?['TimeSection'];
    if (ts is List) {
      for (final day in ts) {
        if (day is! List) continue;
        for (final sec in day) {
          final parts = '$sec'.trim().split(' ');
          if (parts.length < 2 || parts[1] == '00:00:00-00:00:00') continue;
          mask |= int.tryParse(parts[0]) ?? 0;
        }
      }
    }
    final eh = md?['EventHandler'];
    final latch = eh is Map ? (eh['RecordLatch'] as num?)?.toInt() ?? 30 : 30;
    final mdOn = md?['Enable'] == true;
    final off = (mode?['Mode'] as num?)?.toInt() == 2;

    RecMode m;
    if (off || mask == 0) {
      m = RecMode.off;
    } else if (mask & 1 != 0) {
      m = RecMode.continuous;
    } else {
      m = RecMode.motion;
    }
    return RecordSettings(m, latch, mdOn);
  }

  Future<void> write(RecMode mode, int latch) async {
    // 1) Agenda do cartão: 24 h por dia com o tipo escolhido.
    final recT = await _table('Record');
    final rec = _row(recT);
    if (recT != null && rec != null) {
      final mask = switch (mode) {
        RecMode.continuous => _maskContinuous,
        RecMode.motion => _maskMotion,
        RecMode.off => 0,
      };
      rec['TimeSection'] = [
        for (var d = 0; d < 7; d++)
          [
            '$mask 00:00:00-24:00:00',
            for (var i = 0; i < 5; i++) '0 00:00:00-24:00:00',
          ],
      ];
      await _set('Record', recT);
    }

    // 2) Modo geral: 0 = automático (segue a agenda), 2 = desligado.
    final modeT = await _table('RecordMode');
    final mrow = _row(modeT);
    if (modeT != null && mrow != null && mrow.containsKey('Mode')) {
      mrow['Mode'] = mode == RecMode.off ? 2 : 0;
      await _set('RecordMode', modeT);
    }

    // 3) Detecção de movimento ligada e mandando gravar.
    if (mode != RecMode.off) {
      final mdT = await _table('MotionDetect');
      final md = _row(mdT);
      if (mdT != null && md != null) {
        md['Enable'] = true;
        final eh = md['EventHandler'];
        if (eh is Map) {
          final h = Map<String, dynamic>.from(eh);
          h['RecordEnable'] = true;
          h['RecordLatch'] = latch;
          final chans = h['RecordChannels'];
          if (chans is List && !chans.contains(_ch)) h['RecordChannels'] = [...chans, _ch];
          if (chans == null) h['RecordChannels'] = [_ch];
          md['EventHandler'] = h;
        }
        await _set('MotionDetect', mdT);
      } else if (mode == RecMode.motion) {
        throw HttpUnavailable('A câmera não tem a configuração de detecção de movimento.');
      }
    }
  }
}

/// Cartão na tela do Cartão SD para escolher o modo de gravação.
class RecordModeCard extends StatefulWidget {
  const RecordModeCard({super.key, required this.cfg});
  final CameraConfig cfg;

  @override
  State<RecordModeCard> createState() => _RecordModeCardState();
}

class _RecordModeCardState extends State<RecordModeCard> {
  late final RecordModeControl _ctl = RecordModeControl(widget.cfg);
  RecordSettings? _s;
  RecMode _mode = RecMode.motion;
  int _latch = 30;
  bool _busy = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final s = await _ctl.read();
      if (!mounted) return;
      setState(() {
        _s = s;
        _mode = s.mode;
        _latch = const [10, 30, 60, 120].contains(s.latch) ? s.latch : 30;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _ctl.write(_mode, _latch);
      await _load();
      messenger.showSnackBar(const SnackBar(content: Text('Modo de gravação salvo na câmera.')));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final changed = _s != null && (_s!.mode != _mode || _s!.latch != _latch);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.fiber_smart_record_outlined),
            SizedBox(width: 8),
            Text('Gravação no cartão', style: TextStyle(fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 10),
          if (_busy)
            const LinearProgressIndicator()
          else if (_s == null)
            Text(
              'Não consegui ler da câmera: ${_error ?? ''}\n'
              'Alternativa: no Mibo Smart, configurações da câmera → Armazenamento → '
              'modo de gravação "Evento".',
              style: const TextStyle(color: Colors.orangeAccent, fontSize: 13),
            )
          else ...[
            SegmentedButton<RecMode>(
              segments: const [
                ButtonSegment(value: RecMode.motion, label: Text('Só movimento')),
                ButtonSegment(value: RecMode.continuous, label: Text('Contínua')),
                ButtonSegment(value: RecMode.off, label: Text('Desligada')),
              ],
              selected: {_mode},
              onSelectionChanged: (v) => setState(() => _mode = v.first),
            ),
            const SizedBox(height: 8),
            Text(
              switch (_mode) {
                RecMode.motion =>
                  'Grava só quando algo se mexe. Economiza muito o cartão.',
                RecMode.continuous =>
                  'Grava o tempo todo. Quando enche, apaga as gravações mais antigas.',
                RecMode.off => 'A câmera não grava no cartão.',
              },
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
            if (_mode == RecMode.motion) ...[
              const SizedBox(height: 8),
              Row(children: [
                const Expanded(child: Text('Continuar gravando depois do movimento')),
                DropdownButton<int>(
                  value: _latch,
                  items: const [
                    DropdownMenuItem(value: 10, child: Text('10 s')),
                    DropdownMenuItem(value: 30, child: Text('30 s')),
                    DropdownMenuItem(value: 60, child: Text('1 min')),
                    DropdownMenuItem(value: 120, child: Text('2 min')),
                  ],
                  onChanged: (v) => setState(() => _latch = v ?? 30),
                ),
              ]),
            ],
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_error!,
                    style: const TextStyle(color: Colors.orangeAccent, fontSize: 13)),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: changed ? _save : null,
                child: const Text('Salvar na câmera'),
              ),
            ),
          ],
        ]),
      ),
    );
  }
}
