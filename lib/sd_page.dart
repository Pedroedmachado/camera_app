import 'dart:io';

import 'package:flutter/material.dart';

import 'config.dart';
import 'dahua_http.dart';
import 'playback_page.dart';
import 'rec_saver.dart';
import 'record_mode.dart';
import 'timeline.dart';
import 'sd_api.dart';
import 'player_util.dart';

/// Tela do cartão de memória: uso, gravações por dia, assistir, baixar e apagar.
class SdPage extends StatefulWidget {
  const SdPage({super.key, required this.cfg});
  final CameraConfig cfg;

  @override
  State<SdPage> createState() => _SdPageState();
}

class _SdPageState extends State<SdPage> {
  late final DahuaHttp _http = DahuaHttp(
    host: widget.cfg.host.trim(),
    port: widget.cfg.httpPort,
    user: widget.cfg.user,
    password: widget.cfg.password,
  );

  SdApi? _api;
  bool _checking = true;
  String? _apiError; // API web indisponível → só modo por horário
  List<StorageDisk> _disks = const [];
  String? _diskError;

  DateTime _day = DateTime.now();
  DateTime _sel = DateTime.now().subtract(const Duration(minutes: 5));
  List<Recording>? _recs;
  bool _loadingRecs = false;
  String? _recsError;
  bool _onlyMotion = false;

  bool _formatting = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    setState(() {
      _checking = true;
      _apiError = null;
    });
    try {
      final api = await SdApi.open(_http);
      if (!mounted) return;
      setState(() {
        _api = api;
        _checking = false;
      });
      await Future.wait([_loadDisks(), _loadRecs()]);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _apiError = e.toString();
      });
    }
  }

  Future<void> _loadDisks() async {
    try {
      final d = await _api!.storage();
      if (mounted) {
        setState(() {
          _disks = d;
          _diskError = d.isEmpty ? 'Nenhum cartão de memória encontrado na câmera.' : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _diskError = e.toString());
    }
  }

  Future<void> _loadRecs() async {
    setState(() {
      _loadingRecs = true;
      _recsError = null;
    });
    final from = DateTime(_day.year, _day.month, _day.day);
    final to = from.add(const Duration(hours: 23, minutes: 59, seconds: 59));
    try {
      final r = await _api!.findRecordings(from, to, channel: widget.cfg.channel);
      if (mounted) {
        setState(() {
          _recs = r;
          _sel = _defaultSelection(r);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _recs = null;
          _recsError = e.toString();
        });
      }
    } finally {
      if (mounted) setState(() => _loadingRecs = false);
    }
  }

  void _changeDay(int delta) {
    final next = _day.add(Duration(days: delta));
    if (next.isAfter(DateTime.now())) return;
    setState(() {
      _day = next;
      _recs = null;
      _sel = _defaultSelection(const []);
    });
    if (_apiError == null) _loadRecs();
  }

  Future<void> _pickDay() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _day,
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now(),
    );
    if (d != null) {
      setState(() {
        _day = d;
        _recs = null;
        _sel = _defaultSelection(const []);
      });
      if (_apiError == null) _loadRecs();
    }
  }

  void _play(DateTime start, DateTime end, {Recording? rec}) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaybackPage(
        cfg: widget.cfg,
        start: start,
        end: end,
        recording: rec,
        api: _apiError == null ? _api : null,
      ),
    ));
  }

  /// Começa no último movimento do dia (ou na última gravação, ou agora).
  DateTime _defaultSelection(List<Recording> recs) {
    final motion = recs.where((r) => r.isMotion).toList();
    final pick = motion.isNotEmpty ? motion : recs;
    if (pick.isNotEmpty) {
      return pick.reduce((a, b) => a.start.isAfter(b.start) ? a : b).start;
    }
    final now = DateTime.now();
    final dayStart = DateTime(_day.year, _day.month, _day.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    if (now.isAfter(dayStart) && now.isBefore(dayEnd)) {
      return now.subtract(const Duration(minutes: 5));
    }
    return dayStart.add(const Duration(hours: 12));
  }

  Recording? _recAt(DateTime t) {
    for (final r in _recs ?? const <Recording>[]) {
      if (!t.isBefore(r.start) && t.isBefore(r.end)) return r;
    }
    return null;
  }

  void _jumpEvent(int dir) {
    final all = [...?_recs]..sort((a, b) => a.start.compareTo(b.start));
    final motion = all.where((r) => r.isMotion).toList();
    final list = motion.isNotEmpty ? motion : all;
    Recording? target;
    if (dir > 0) {
      for (final r in list) {
        if (r.start.isAfter(_sel.add(const Duration(seconds: 1)))) {
          target = r;
          break;
        }
      }
    } else {
      for (final r in list.reversed) {
        if (r.start.isBefore(_sel.subtract(const Duration(seconds: 1)))) {
          target = r;
          break;
        }
      }
    }
    if (target == null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(dir > 0 ? 'Não há evento depois.' : 'Não há evento antes.')));
      return;
    }
    setState(() => _sel = target!.start);
  }

  /// Abre a reprodução no momento escolhido (até 1 hora ou até agora).
  void _openAt(PlaybackAction action) {
    final start = _sel;
    var end = start.add(const Duration(hours: 1));
    final now = DateTime.now();
    if (end.isAfter(now)) end = now;
    if (end.difference(start) < const Duration(seconds: 5)) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Escolha um momento um pouco antes de agora.')));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => PlaybackPage(
        cfg: widget.cfg,
        start: start,
        end: end,
        recording: _recAt(start),
        api: _apiError == null ? _api : null,
        autoAction: action,
      ),
    ));
  }

  Widget _timelineCard() {
    final rec = _recAt(_sel);
    final status = _apiError != null
        ? ''
        : (rec == null
            ? ' · sem gravação aqui'
            : (rec.isMotion ? ' · movimento' : ' · gravação'));
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DayTimeline(
            day: _day,
            recordings: _recs ?? const [],
            selected: _sel,
            onSelect: (t) => setState(() => _sel = t),
          ),
          const SizedBox(height: 6),
          Row(children: [
            IconButton(
              tooltip: 'Evento anterior',
              icon: const Icon(Icons.skip_previous),
              onPressed: () => _jumpEvent(-1),
            ),
            Expanded(
              child: Text(
                '${hms(_sel)}$status',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontWeight: FontWeight.bold,
                  color: rec?.isMotion == true ? Colors.amberAccent : null,
                ),
              ),
            ),
            IconButton(
              tooltip: 'Próximo evento',
              icon: const Icon(Icons.skip_next),
              onPressed: () => _jumpEvent(1),
            ),
          ]),
          const SizedBox(height: 4),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: () => _openAt(PlaybackAction.none),
                icon: const Icon(Icons.play_arrow),
                label: const Text('Assistir daqui'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _openAt(PlaybackAction.snapshot),
                icon: const Icon(Icons.photo_camera_outlined),
                label: const Text('Foto do momento'),
              ),
              FilledButton.tonalIcon(
                onPressed: () => _openAt(PlaybackAction.record),
                icon: const Icon(Icons.fiber_manual_record, color: Colors.redAccent),
                label: const Text('Gravar daqui'),
              ),
            ],
          ),
        ]),
      ),
    );
  }

  Future<void> _format(StorageDisk disk) async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => StatefulBuilder(
        builder: (c, set) => AlertDialog(
          title: const Text('Apagar tudo do cartão?'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text(
              'Todas as gravações do cartão serão apagadas para sempre. '
              'A câmera continua gravando normalmente depois.\n\n'
              'Digite APAGAR para confirmar:',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: ctrl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              onChanged: (_) => set(() {}),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(c, false),
                child: const Text('Cancelar')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
              onPressed: ctrl.text.trim().toUpperCase() == 'APAGAR'
                  ? () => Navigator.pop(c, true)
                  : null,
              child: const Text('Apagar tudo'),
            ),
          ],
        ),
      ),
    );
    ctrl.dispose();
    if (ok != true || !mounted) return;
    setState(() => _formatting = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _api!.format(disk);
      messenger.showSnackBar(const SnackBar(
          content: Text('Cartão sendo apagado. Pode levar até 1 minuto.')));
      await Future.delayed(const Duration(seconds: 15));
      await _loadDisks();
      await _loadRecs();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => _formatting = false);
    }
  }

  /// Salva uma ou várias gravações como vídeo, com janela de progresso.
  Future<void> _saveVideos(List<Recording> recs) async {
    final api = _api;
    if (api == null || recs.isEmpty) return;
    var cancel = false;
    var index = 0;
    var status = '';
    double? progress;
    var saved = 0;
    final errors = <String>[];
    StateSetter? setDialog;
    var closed = false;
    void refresh(VoidCallback fn) {
      if (!closed && !cancel) setDialog?.call(fn);
    }

    final dialog = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (c) => StatefulBuilder(builder: (c, set) {
        setDialog = set;
        return AlertDialog(
          title: Text(recs.length == 1
              ? 'Salvando vídeo'
              : 'Salvando ${index + 1} de ${recs.length}'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            if (index < recs.length)
              Text('${hms(recs[index].start)} – ${hms(recs[index].end)}'),
            const SizedBox(height: 10),
            LinearProgressIndicator(value: progress),
            const SizedBox(height: 8),
            Text(status, style: const TextStyle(color: Colors.white70)),
          ]),
          actions: [
            TextButton(
              onPressed: () {
                cancel = true;
                Navigator.pop(c);
              },
              child: const Text('Cancelar'),
            ),
          ],
        );
      }),
    );
    dialog.then((_) => closed = true);

    for (index = 0; index < recs.length && !cancel; index++) {
      refresh(() {
        status = 'Começando…';
        progress = null;
      });
      try {
        await saveRecordingAsVideo(api, recs[index],
            cancelled: () => cancel,
            onStatus: (st, pr) => refresh(() {
                  status = st;
                  progress = pr;
                }));
        saved++;
      } catch (e) {
        if (!cancel) errors.add('${hms(recs[index].start)}: $e');
      }
    }
    if (!cancel && !closed && mounted) Navigator.of(context, rootNavigator: true).pop();
    await dialog;
    if (!mounted) return;
    final msg = StringBuffer('$saved vídeo(s) salvo(s) na Galeria');
    if (Platform.isAndroid) msg.write(' e na galeria do celular (álbum CamLivre)');
    msg.write('.');
    if (errors.isNotEmpty) msg.write('\n${errors.length} com erro: ${errors.first}');
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg.toString()), duration: const Duration(seconds: 6)));
  }

  // ---------- interface ----------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cartão SD'),
        actions: [
          IconButton(
            tooltip: 'Atualizar',
            icon: const Icon(Icons.refresh),
            onPressed: _init,
          ),
        ],
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                if (_apiError == null) {
                  await Future.wait([_loadDisks(), _loadRecs()]);
                } else {
                  await _init();
                }
              },
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  if (_apiError != null) _apiUnavailableCard(),
                  _dayBar(),
                  _timelineCard(),
                  if (_apiError == null) ..._recordingList(),
                  const SizedBox(height: 8),
                  if (_apiError == null) _storageCard(),
                  if (_apiError == null) RecordModeCard(cfg: widget.cfg),
                ],
              ),
            ),
    );
  }

  Widget _apiUnavailableCard() {
    return Card(
      color: Colors.orange.withValues(alpha: 0.15),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Row(children: [
            Icon(Icons.info_outline, color: Colors.orangeAccent),
            SizedBox(width: 8),
            Expanded(
                child: Text('Lista e apagar indisponíveis',
                    style: TextStyle(fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 8),
          Text(_apiError!),
          const SizedBox(height: 8),
          const Text(
            'Você ainda pode assistir e gravar trechos do cartão escolhendo o horário abaixo. '
            'Se a câmera usa outra porta web, ajuste em Configurações → Avançado.',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(onPressed: _init, child: const Text('Tentar de novo')),
          ),
        ]),
      ),
    );
  }

  Widget _storageCard() {
    if (_diskError != null) {
      return Card(
        child: ListTile(
          leading: const Icon(Icons.sd_card_alert_outlined),
          title: Text(_diskError!),
        ),
      );
    }
    if (_disks.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: LinearProgressIndicator(),
        ),
      );
    }
    return Column(children: [
      for (final d in _disks)
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(d.isError ? Icons.sd_card_alert : Icons.sd_card,
                    color: d.isError ? Colors.redAccent : null),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '${formatBytes(d.usedBytes)} de ${formatBytes(d.totalBytes)} usados',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
                if (d.state.isNotEmpty)
                  Text(d.state, style: const TextStyle(color: Colors.white54)),
              ]),
              const SizedBox(height: 10),
              LinearProgressIndicator(value: d.usedFraction.clamp(0.0, 1.0)),
              const SizedBox(height: 10),
              Align(
                alignment: Alignment.centerRight,
                child: _formatting
                    ? const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('Apagando…'),
                      )
                    : OutlinedButton.icon(
                        style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.redAccent),
                        onPressed: () => _format(d),
                        icon: const Icon(Icons.delete_forever_outlined),
                        label: const Text('Apagar tudo'),
                      ),
              ),
            ]),
          ),
        ),
    ]);
  }

  Widget _dayBar() {
    final today = DateTime.now();
    final isToday = _day.year == today.year &&
        _day.month == today.month &&
        _day.day == today.day;
    return Row(children: [
      IconButton(
          onPressed: () => _changeDay(-1), icon: const Icon(Icons.chevron_left)),
      Expanded(
        child: TextButton.icon(
          onPressed: _pickDay,
          icon: const Icon(Icons.calendar_today, size: 18),
          label: Text(isToday ? 'Hoje, ${dmy(_day)}' : dmy(_day)),
        ),
      ),
      IconButton(
          onPressed: isToday ? null : () => _changeDay(1),
          icon: const Icon(Icons.chevron_right)),
    ]);
  }

  List<Widget> _recordingList() {
    if (_loadingRecs) {
      return const [
        Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      ];
    }
    if (_recsError != null) {
      return [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('Não consegui listar: $_recsError'),
        )
      ];
    }
    final all = _recs ?? const <Recording>[];
    final list = _onlyMotion ? all.where((r) => r.isMotion).toList() : all;
    final total = all.fold<Duration>(Duration.zero, (a, r) => a + r.duration);
    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
        child: Row(children: [
          Expanded(
            child: Text(
              all.isEmpty
                  ? 'Nenhuma gravação neste dia.'
                  : '${all.length} gravações · ${formatDuration(total)}',
              style: const TextStyle(color: Colors.white70),
            ),
          ),
          FilterChip(
            label: const Text('Só movimento'),
            selected: _onlyMotion,
            onSelected: (v) => setState(() => _onlyMotion = v),
          ),
        ]),
      ),
      if (all.any((r) => r.isMotion))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: FilledButton.tonalIcon(
            onPressed: () => _saveVideos(all.where((r) => r.isMotion).toList()),
            icon: const Icon(Icons.video_library_outlined),
            label: Text(
                'Salvar os ${all.where((r) => r.isMotion).length} eventos de movimento como vídeo'),
          ),
        ),
      for (final r in list)
        Card(
          child: ListTile(
            leading: Icon(
              r.isMotion ? Icons.directions_run : Icons.videocam_outlined,
              color: r.isMotion ? Colors.amberAccent : null,
            ),
            title: Text('${hms(r.start)} – ${hms(r.end)}'),
            subtitle: Text(
                '${formatDuration(r.duration)}${r.isMotion ? ' · movimento' : ''}'),
            trailing: PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'play') _play(r.start, r.end, rec: r);
                if (v == 'save') _saveVideos([r]);
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'play', child: Text('Assistir')),
                PopupMenuItem(value: 'save', child: Text('Salvar como vídeo (MP4)')),
              ],
            ),
            onTap: () => _play(r.start, r.end, rec: r),
          ),
        ),
      const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          'A câmera não permite apagar uma gravação sozinha — só o cartão inteiro, '
          'em “Apagar tudo”.',
          style: TextStyle(color: Colors.white38, fontSize: 12),
        ),
      ),
    ];
  }
}
