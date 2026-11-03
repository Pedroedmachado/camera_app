// Autoteste da parte de vídeo (roda no GitHub Actions com ffmpeg + mediamtx).
// Uso: dart run tool/selftest.dart <pasta-de-trabalho>

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:camlivre/media/dav_reader.dart';
import 'package:camlivre/media/live_session.dart';
import 'package:camlivre/media/nal.dart';

var failures = 0;

void check(bool ok, String what) {
  stdout.writeln('${ok ? 'OK  ' : 'FAIL'} $what');
  if (!ok) failures++;
}

Future<ProcessResult> run(String exe, List<String> args) async {
  final r = await Process.run(exe, args);
  if (r.exitCode != 0) {
    stdout.writeln('  ! $exe ${args.join(' ')}\n${r.stderr}');
  }
  return r;
}

Future<Map<String, dynamic>> probe(String file) async {
  final r = await run('ffprobe', [
    '-v', 'error', '-print_format', 'json', '-show_streams', '-show_format',
    '-count_frames', file,
  ]);
  return jsonDecode(r.stdout as String) as Map<String, dynamic>;
}

Future<bool> decodesClean(String file) async {
  final r = await Process.run('ffmpeg', ['-v', 'error', '-i', file, '-f', 'null', '-']);
  final err = (r.stderr as String).trim();
  if (err.isNotEmpty) stdout.writeln('  decode: ${err.split('\n').take(5).join(' | ')}');
  return r.exitCode == 0;
}

/// Monta um .dav falso no formato Dahua a partir de um fluxo Annex-B com AUD.
Future<void> makeDav(String es, String dav, VideoCodec codec, int fps, DateTime start) async {
  final data = await File(es).readAsBytes();
  final nals = splitAnnexB(data);
  final frames = <List<Uint8List>>[];
  for (final n in nals) {
    final t = nalType(codec, n);
    final aud = codec == VideoCodec.h264 ? t == 9 : t == 35;
    if (aud || frames.isEmpty) frames.add([]);
    if (!aud) frames.last.add(n);
  }
  final out = BytesBuilder();
  var ms = 0;
  for (var i = 0; i < frames.length; i++) {
    final f = frames[i];
    if (f.isEmpty) continue;
    final key = f.any((n) => isKeyNal(codec, nalType(codec, n)));
    final payload = BytesBuilder();
    for (final n in f) {
      payload.add([0, 0, 0, 1]);
      payload.add(n);
    }
    final p = payload.toBytes();
    const ext = 8;
    final len = 24 + ext + p.length + 8;
    final wall = start.add(Duration(milliseconds: ms));
    final dt = (wall.second) |
        (wall.minute << 6) |
        (wall.hour << 12) |
        (wall.day << 17) |
        (wall.month << 22) |
        ((wall.year - 2000) << 26);
    final h = ByteData(24);
    h.setUint8(0, 0x44);
    h.setUint8(1, 0x48);
    h.setUint8(2, 0x41);
    h.setUint8(3, 0x56);
    h.setUint8(4, key ? 0xFD : 0xFC);
    h.setUint32(8, i, Endian.little);
    h.setUint32(12, len, Endian.little);
    h.setUint32(16, dt, Endian.little);
    h.setUint16(20, ms & 0xFFFF, Endian.little);
    h.setUint8(22, ext);
    out.add(h.buffer.asUint8List());
    out.add(List.filled(ext, 0));
    out.add(p);
    out.add('dhav'.codeUnits);
    final tail = ByteData(4)..setUint32(0, len, Endian.little);
    out.add(tail.buffer.asUint8List());
    // Um bloco de áudio no meio, que deve ser ignorado.
    if (i % 5 == 0) {
      final a = ByteData(24 + 320 + 8);
      a.setUint8(0, 0x44);
      a.setUint8(1, 0x48);
      a.setUint8(2, 0x41);
      a.setUint8(3, 0x56);
      a.setUint8(4, 0xF0);
      a.setUint32(12, 24 + 320 + 8, Endian.little);
      out.add(a.buffer.asUint8List());
    }
    ms += 1000 ~/ fps;
  }
  await File(dav).writeAsBytes(out.toBytes());
}

Future<void> testDav(String dir, VideoCodec codec) async {
  final name = codec == VideoCodec.h264 ? 'h264' : 'hevc';
  final es = '$dir/test.$name';
  await run('ffmpeg', [
    '-y', '-v', 'error', '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=15',
    '-t', '10',
    if (codec == VideoCodec.h264) ...['-c:v', 'libx264', '-bsf:v', 'h264_metadata=aud=insert']
    else ...['-c:v', 'libx265', '-x265-params', 'log-level=error', '-bsf:v', 'hevc_metadata=aud=insert'],
    '-g', '30', '-bf', '0', es,
  ]);
  final dav = '$dir/test_$name.dav';
  final start = DateTime(2026, 11, 3, 10, 0, 0);
  await makeDav(es, dav, codec, 15, start);

  final mp4 = File('$dir/out_$name.mp4');
  final info = await DavReader.toMp4(File(dav), mp4);
  check(info.codec == codec, '[$name] codec detectado');
  final pr = await probe(mp4.path);
  final st = (pr['streams'] as List).first as Map;
  check(st['codec_name'] == (codec == VideoCodec.h264 ? 'h264' : 'hevc'), '[$name] MP4 codec ${st['codec_name']}');
  check(st['width'] == 640 && st['height'] == 360, '[$name] tamanho ${st['width']}x${st['height']}');
  final nb = int.tryParse('${st['nb_read_frames']}') ?? 0;
  check(nb >= 145 && nb <= 150, '[$name] quadros $nb (esperado ~150)');
  final dur = double.tryParse('${(pr['format'] as Map)['duration']}') ?? 0;
  check(dur > 9.5 && dur < 10.5, '[$name] duração ${dur.toStringAsFixed(2)} s');
  check(await decodesClean(mp4.path), '[$name] MP4 decodifica sem erros');

  // Corte de trecho: 10:00:03 → 10:00:06
  final cut = File('$dir/cut_$name.mp4');
  await DavReader.toMp4(File(dav), cut,
      from: start.add(const Duration(seconds: 3)), to: start.add(const Duration(seconds: 6)));
  final pc = await probe(cut.path);
  final cd = double.tryParse('${(pc['format'] as Map)['duration']}') ?? 0;
  check(cd > 2.5 && cd < 6.5, '[$name] trecho cortado ${cd.toStringAsFixed(2)} s');
  check(await decodesClean(cut.path), '[$name] trecho decodifica sem erros');
}

Future<void> testLive(String dir, VideoCodec codec) async {
  final name = codec == VideoCodec.h264 ? 'h264' : 'hevc';
  final pub = await Process.start('ffmpeg', [
    '-v', 'error', '-re',
    '-f', 'lavfi', '-i', 'testsrc=size=640x360:rate=15',
    '-f', 'lavfi', '-i', 'sine=frequency=440:sample_rate=8000',
    if (codec == VideoCodec.h264) ...['-c:v', 'libx264', '-tune', 'zerolatency']
    else ...['-c:v', 'libx265', '-x265-params', 'log-level=error'],
    '-g', '15', '-bf', '0',
    '-c:a', 'pcm_alaw', '-ar', '8000', '-ac', '1',
    '-f', 'rtsp', '-rtsp_transport', 'tcp',
    'rtsp://pub:pub@127.0.0.1:8554/cam/realmonitor',
  ]);
  pub.stderr.transform(utf8.decoder).listen((e) => stdout.write('  ffmpeg: $e'));
  await Future.delayed(const Duration(seconds: 4));

  final s = LiveSession(
    host: '127.0.0.1',
    port: 8554,
    user: 'admin',
    password: 'segredo',
    path: '/cam/realmonitor?channel=1&subtype=0',
  );
  try {
    await s.start();
    final url = await s.url.timeout(const Duration(seconds: 15));
    check(url.startsWith('http://127.0.0.1:'), '[$name] ao vivo pronto: $url');
    check(s.codec == codec, '[$name] codec ao vivo ${s.codec}');

    // Lê 5 s do MKV como o player leria.
    final mkv = File('$dir/live_$name.mkv');
    final sink = mkv.openWrite();
    final client = HttpClient();
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    final sub = res.listen(sink.add);
    final rec = File('$dir/rec_$name.mp4');
    await s.startRecording(rec);
    await Future.delayed(const Duration(seconds: 5));
    final saved = await s.stopRecording();
    await sub.cancel();
    await sink.close();
    client.close(force: true);

    final pm = await probe(mkv.path);
    final streams = (pm['streams'] as List).cast<Map>();
    final v = streams.where((x) => x['codec_type'] == 'video').toList();
    final a = streams.where((x) => x['codec_type'] == 'audio').toList();
    check(v.isNotEmpty && v.first['width'] == 640, '[$name] MKV ao vivo tem vídeo 640x360');
    final vf = v.isEmpty ? 0 : int.tryParse('${v.first['nb_read_frames']}') ?? 0;
    check(vf >= 45, '[$name] MKV ao vivo quadros $vf (esperado ~75)');
    check(a.isNotEmpty && a.first['codec_name'] == 'pcm_s16le', '[$name] MKV ao vivo tem áudio PCM');
    check(await decodesClean(mkv.path), '[$name] MKV ao vivo decodifica sem erros');

    check(saved != null, '[$name] gravação ao vivo criou o MP4');
    if (saved != null) {
      final pr = await probe(saved.path);
      final d = double.tryParse('${(pr['format'] as Map)['duration']}') ?? 0;
      check(d > 3 && d < 6.5, '[$name] gravação ${d.toStringAsFixed(2)} s');
      check(await decodesClean(saved.path), '[$name] gravação decodifica sem erros');
    }

    // Senha errada deve dar mensagem clara.
    final bad = LiveSession(
        host: '127.0.0.1', port: 8554, user: 'admin', password: 'errada',
        path: '/cam/realmonitor');
    var msg = '';
    try {
      await bad.start();
    } catch (e) {
      msg = '$e';
    }
    await bad.close();
    check(msg.contains('Senha errada'), '[$name] senha errada → "$msg"');
  } catch (e, st) {
    check(false, '[$name] ao vivo: $e\n$st');
  } finally {
    await s.close();
    pub.kill();
    await pub.exitCode;
  }
}

Future<void> main(List<String> args) async {
  final dir = args.isEmpty ? Directory.systemTemp.createTempSync('camlivre').path : args.first;
  await Directory(dir).create(recursive: true);
  await testDav(dir, VideoCodec.h264);
  await testDav(dir, VideoCodec.h265);
  if (args.length > 1 && args[1] == 'live') {
    await testLive(dir, VideoCodec.h264);
    await testLive(dir, VideoCodec.h265);
  }
  stdout.writeln(failures == 0 ? '\nTUDO OK' : '\n$failures FALHA(S)');
  exit(failures == 0 ? 0 : 1);
}
