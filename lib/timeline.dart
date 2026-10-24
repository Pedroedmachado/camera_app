import 'dart:math';

import 'package:flutter/material.dart';

import 'dahua_http.dart';
import 'player_util.dart';

/// Linha do tempo de um dia: mostra onde há gravação (azul) e movimento
/// (amarelo). Toque ou arraste para escolher o momento.
class DayTimeline extends StatefulWidget {
  const DayTimeline({
    super.key,
    required this.day,
    required this.recordings,
    required this.selected,
    required this.onSelect,
  });

  final DateTime day;
  final List<Recording> recordings;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  State<DayTimeline> createState() => _DayTimelineState();
}

class _DayTimelineState extends State<DayTimeline> {
  static const _spans = [24.0, 6.0, 1.0]; // horas visíveis
  int _zoom = 0;
  double _start = 0; // hora inicial da janela visível

  double get _span => _spans[_zoom];

  DateTime get _dayStart => DateTime(widget.day.year, widget.day.month, widget.day.day);

  double _hourOf(DateTime t) => t.difference(_dayStart).inSeconds / 3600.0;

  DateTime _timeOf(double h) =>
      _dayStart.add(Duration(seconds: (h.clamp(0.0, 24.0) * 3600).round()));

  void _setZoom(int z) {
    setState(() {
      _zoom = z;
      _center(_hourOf(widget.selected));
    });
  }

  void _center(double h) {
    _start = (h - _span / 2).clamp(0.0, 24.0 - _span);
  }

  void _pan(double hours) {
    setState(() => _start = (_start + hours).clamp(0.0, 24.0 - _span));
  }

  void _selectAt(double dx, double width) {
    final h = _start + (dx / width).clamp(0.0, 1.0) * _span;
    var t = _timeOf(h);
    final now = DateTime.now();
    if (t.isAfter(now)) t = now;
    widget.onSelect(t);
  }

  @override
  void didUpdateWidget(DayTimeline old) {
    super.didUpdateWidget(old);
    // Mantém o cursor visível quando ele muda por botão (próximo evento etc.).
    final h = _hourOf(widget.selected);
    if (h < _start || h > _start + _span) _center(h);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        for (var i = 0; i < _spans.length; i++)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: ChoiceChip(
              label: Text(_spans[i] == 1 ? '1 h' : '${_spans[i].toInt()} h'),
              selected: _zoom == i,
              onSelected: (_) => _setZoom(i),
              visualDensity: VisualDensity.compact,
            ),
          ),
        const Spacer(),
        if (_zoom > 0) ...[
          IconButton(
            tooltip: 'Voltar',
            icon: const Icon(Icons.chevron_left),
            onPressed: _start <= 0 ? null : () => _pan(-_span / 2),
          ),
          IconButton(
            tooltip: 'Avançar',
            icon: const Icon(Icons.chevron_right),
            onPressed: _start >= 24 - _span ? null : () => _pan(_span / 2),
          ),
        ],
      ]),
      LayoutBuilder(builder: (context, c) {
        final w = c.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => _selectAt(d.localPosition.dx, w),
          onHorizontalDragUpdate: (d) => _selectAt(d.localPosition.dx, w),
          child: SizedBox(
            height: 74,
            width: w,
            child: CustomPaint(
              painter: _TimelinePainter(
                start: _start,
                span: _span,
                recs: [
                  for (final r in widget.recordings)
                    _Seg(_hourOf(r.start), _hourOf(r.end), r.isMotion),
                ],
                cursor: _hourOf(widget.selected),
                now: _hourOf(DateTime.now()),
                cursorLabel: hms(widget.selected),
              ),
            ),
          ),
        );
      }),
      const SizedBox(height: 4),
      const Row(children: [
        _Legend(color: Color(0xFF4F7BD9), text: 'Gravação'),
        SizedBox(width: 14),
        _Legend(color: Color(0xFFFFC23D), text: 'Movimento'),
        Spacer(),
        Text('Toque ou arraste para escolher',
            style: TextStyle(color: Colors.white38, fontSize: 11)),
      ]),
    ]);
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.text});
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 12, height: 12, color: color),
        const SizedBox(width: 4),
        Text(text, style: const TextStyle(fontSize: 12, color: Colors.white70)),
      ]);
}

class _Seg {
  final double a, b;
  final bool motion;
  _Seg(this.a, this.b, this.motion);
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter({
    required this.start,
    required this.span,
    required this.recs,
    required this.cursor,
    required this.now,
    required this.cursorLabel,
  });

  final double start, span, cursor, now;
  final List<_Seg> recs;
  final String cursorLabel;

  static const _rec = Color(0xFF4F7BD9);
  static const _motion = Color(0xFFFFC23D);

  @override
  void paint(Canvas canvas, Size size) {
    const top = 22.0, barH = 30.0;
    double x(double h) => (h - start) / span * size.width;

    final bg = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, top, size.width, barH), const Radius.circular(6));
    canvas.save();
    canvas.clipRRect(bg);
    canvas.drawRRect(bg, Paint()..color = const Color(0x22FFFFFF));

    // Futuro (depois de agora) mais escuro.
    if (now < start + span) {
      canvas.drawRect(
          Rect.fromLTRB(max(0, x(now)), top, size.width, top + barH),
          Paint()..color = const Color(0x55000000));
    }

    // Gravações comuns primeiro, movimento por cima.
    for (final motion in [false, true]) {
      final paint = Paint()..color = motion ? _motion : _rec;
      for (final s in recs) {
        if (s.motion != motion) continue;
        if (s.b < start || s.a > start + span) continue;
        var l = x(s.a), r = x(s.b);
        if (r - l < 2) r = l + 2; // eventos curtos continuam visíveis
        canvas.drawRect(
            Rect.fromLTRB(l, motion ? top : top + barH * 0.35, r, top + barH), paint);
      }
    }
    canvas.restore();

    // Marcas de hora.
    final step = span >= 24 ? 1.0 : (span >= 6 ? 0.25 : 1 / 12); // 1 h, 15 min, 5 min
    final labelEvery = span >= 24 ? 3.0 : (span >= 6 ? 1.0 : 1 / 6);
    final tick = Paint()
      ..color = const Color(0x66FFFFFF)
      ..strokeWidth = 1;
    final first = (start / step).ceil() * step;
    for (var h = first; h <= start + span + 1e-9; h += step) {
      final px = x(h);
      final isLabel = ((h / labelEvery) - (h / labelEvery).roundToDouble()).abs() < 1e-6;
      canvas.drawLine(Offset(px, top + barH), Offset(px, top + barH + (isLabel ? 8 : 4)), tick);
      if (isLabel) {
        final hh = h.floor();
        final mm = ((h - hh) * 60).round();
        _text(canvas, '${two(hh % 24 == 0 && h >= 24 ? 24 : hh)}:${two(mm)}',
            Offset(px, top + barH + 9), 10, const Color(0x99FFFFFF),
            center: true, maxX: size.width);
      }
    }

    // Cursor do momento escolhido.
    if (cursor >= start && cursor <= start + span) {
      final cx = x(cursor);
      canvas.drawLine(Offset(cx, top - 4), Offset(cx, top + barH + 4),
          Paint()
            ..color = Colors.redAccent
            ..strokeWidth = 2);
      _text(canvas, cursorLabel, Offset(cx, 2), 12, Colors.redAccent,
          center: true, maxX: size.width, bold: true);
    }
  }

  void _text(Canvas c, String s, Offset at, double size, Color color,
      {bool center = false, required double maxX, bool bold = false}) {
    final tp = TextPainter(
      text: TextSpan(
          text: s,
          style: TextStyle(
              fontSize: size, color: color, fontWeight: bold ? FontWeight.bold : null)),
      textDirection: TextDirection.ltr,
    )..layout();
    var dx = center ? at.dx - tp.width / 2 : at.dx;
    dx = dx.clamp(0.0, max(0.0, maxX - tp.width));
    tp.paint(c, Offset(dx, at.dy));
  }

  @override
  bool shouldRepaint(_TimelinePainter o) =>
      o.start != start ||
      o.span != span ||
      o.cursor != cursor ||
      o.recs.length != recs.length ||
      o.now != now;
}
