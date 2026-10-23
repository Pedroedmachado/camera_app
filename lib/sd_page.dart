import 'package:flutter/material.dart';

import 'config.dart';
import 'dahua_http.dart';
import 'playback_page.dart';
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

  bool _checking = true;
  String? _apiError; // API web indisponível → só modo por horário
  List<StorageDisk> _disks = const [];
  String? _diskError;

  DateTime _day = DateTime.now();
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
      await _http.deviceType();
      if (!mounted) return;
      setState(() => _checking = false);
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
      final d = await _http.storage();
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
      final r = await _http.findRecordings(from, to, channel: widget.cfg.channel);
      if (mounted) setState(() => _recs = r);
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
    setState(() => _day = next);
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
      setState(() => _day = d);
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
        http: _apiError == null ? _http : null,
      ),
    ));
  }

  /// Sem lista: escolhe um horário e assiste a partir dele (até 1 hora).
  Future<void> _playAtTime() async {
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.now(),
      helpText: 'Assistir a partir de',
    );
    if (t == null) return;
    final start = DateTime(_day.year, _day.month, _day.day, t.hour, t.minute);
    var end = start.add(const Duration(hours: 1));
    final now = DateTime.now();
    if (end.isAfter(now)) end = now;
    if (!end.isAfter(start)) return;
    _play(start, end);
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
      await _http.format(disk);
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
                  if (_apiError == null) _storageCard(),
                  const SizedBox(height: 8),
                  _dayBar(),
                  const SizedBox(height: 4),
                  Card(
                    child: ListTile(
                      leading: const Icon(Icons.schedule),
                      title: const Text('Assistir a partir de um horário'),
                      subtitle: Text('Dia ${dmy(_day)}'),
                      onTap: _playAtTime,
                    ),
                  ),
                  if (_apiError == null) ..._recordingList(),
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
            trailing: const Icon(Icons.play_circle_outline),
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
