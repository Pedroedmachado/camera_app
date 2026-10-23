import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'rtsp_probe.dart';

/// Resposta HTTP simples.
class HttpResult {
  final int status;
  final String body;
  HttpResult(this.status, this.body);
  bool get ok => status == 200;
}

/// Disco/cartão de memória da câmera.
class StorageDisk {
  final String name; // ex.: /dev/mmc0
  final String path; // partição, ex.: /dev/mmc0p1
  final String state;
  final int totalBytes;
  final int usedBytes;
  final bool isError;
  StorageDisk({
    required this.name,
    required this.path,
    required this.state,
    required this.totalBytes,
    required this.usedBytes,
    required this.isError,
  });
  double get usedFraction => totalBytes == 0 ? 0 : usedBytes / totalBytes;
}

/// Uma gravação no cartão.
class Recording {
  final DateTime start;
  final DateTime end;
  final String filePath;
  final int lengthBytes;
  final List<String> events;
  final List<String> flags;
  Recording({
    required this.start,
    required this.end,
    required this.filePath,
    required this.lengthBytes,
    required this.events,
    required this.flags,
  });

  Duration get duration => end.difference(start);
  bool get isMotion =>
      flags.any((f) => f.toLowerCase() == 'event') ||
      events.any((e) => e.toLowerCase().contains('motion'));
}

class HttpUnavailable implements Exception {
  final String message;
  HttpUnavailable(this.message);
  @override
  String toString() => message;
}

/// Cliente da API web (CGI) das câmeras com base Dahua, como a Mibo.
/// Usa socket direto para mandar os caminhos exatamente como a câmera espera.
class DahuaHttp {
  final String host;
  final int port;
  final String user;
  final String password;

  DahuaHttp({
    required this.host,
    required this.port,
    required this.user,
    required this.password,
  });

  // ---------- HTTP baixo nível ----------

  Future<Socket> _connect() async {
    try {
      return await Socket.connect(host, port,
          timeout: const Duration(seconds: 5));
    } on SocketException {
      throw HttpUnavailable(
          'A câmera não aceita conexão web na porta $port.');
    }
  }

  String _request(String method, String target, String? auth,
      {Map<String, String> headers = const {}, List<int>? body}) {
    final b = StringBuffer()
      ..write('$method $target HTTP/1.1\r\n')
      ..write('Host: $host:$port\r\n')
      ..write('User-Agent: CamLivre\r\n')
      ..write('Connection: close\r\n');
    if (auth != null) b.write('Authorization: $auth\r\n');
    headers.forEach((k, v) => b.write('$k: $v\r\n'));
    if (body != null) b.write('Content-Length: ${body.length}\r\n');
    b.write('\r\n');
    return b.toString();
  }

  /// Abre a requisição (com Digest se a câmera pedir) e devolve o fluxo.
  Future<_OpenResponse> _open(String target,
      {String method = 'GET',
      Map<String, String> headers = const {},
      List<int>? body}) async {
    String? auth;
    for (var round = 0; round < 2; round++) {
      final socket = await _connect();
      socket.write(_request(method, target, auth, headers: headers, body: body));
      if (body != null) socket.add(body);
      final resp = await _OpenResponse.read(socket);
      if (resp.status == 401 && round == 0) {
        await resp.drain();
        final challenges = resp.allHeaders('www-authenticate');
        final digest = challenges.firstWhere(
          (c) => c.toLowerCase().startsWith('digest'),
          orElse: () => challenges.isEmpty ? '' : challenges.first,
        );
        auth = RtspProbe.authHeader(digest, method, target, user, password);
        if (auth == null) return resp;
        continue;
      }
      return resp;
    }
    throw StateError('inalcançável');
  }

  Future<HttpResult> post(String target, String json,
      {Map<String, String> headers = const {}}) async {
    final r = await _open(target,
        method: 'POST',
        headers: {'Content-Type': 'application/json', ...headers},
        body: utf8.encode(json));
    final bytes = await r.readAll();
    return HttpResult(r.status, utf8.decode(bytes, allowMalformed: true));
  }

  Future<HttpResult> get(String target) async {
    final r = await _open(target);
    final bytes = await r.readAll();
    return HttpResult(r.status, utf8.decode(bytes, allowMalformed: true));
  }

  /// Converte "a.b[0].c=valor" em mapa.
  static Map<String, String> table(String body) {
    final m = <String, String>{};
    for (final line in const LineSplitter().convert(body)) {
      final i = line.indexOf('=');
      if (i > 0) m[line.substring(0, i).trim()] = line.substring(i + 1).trim();
    }
    return m;
  }

  static String _q(String v) => Uri.encodeComponent(v);

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  static DateTime? _parseTime(String? s) {
    if (s == null) return null;
    final m = RegExp(r'(\d+)-(\d+)-(\d+)[ T](\d+):(\d+):(\d+)').firstMatch(s);
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  }

  void _check(HttpResult r) {
    if (r.status == 401) {
      throw HttpUnavailable('Senha recusada pela API web da câmera.');
    }
    if (r.status == 404 || r.status == 501) {
      throw HttpUnavailable('Esta câmera não tem essa função na API web.');
    }
    if (!r.ok) throw HttpUnavailable('A câmera respondeu erro ${r.status}.');
  }

  // ---------- funções ----------

  /// Confirma que a API web existe e a senha funciona.
  Future<String> deviceType() async {
    final r = await get('/cgi-bin/magicBox.cgi?action=getDeviceType');
    _check(r);
    return table(r.body)['type'] ?? r.body.trim();
  }

  Future<List<StorageDisk>> storage() async {
    final r = await get('/cgi-bin/storageDevice.cgi?action=getDeviceAllInfo');
    _check(r);
    final t = table(r.body);
    final disks = <StorageDisk>[];
    for (var i = 0; i < 8; i++) {
      final name = t['list.info[$i].Name'];
      if (name == null) break;
      var total = 0, used = 0;
      var path = name;
      var err = false;
      for (var j = 0; j < 8; j++) {
        final p = 'list.info[$i].Detail[$j]';
        if (!t.containsKey('$p.TotalBytes')) break;
        total += double.tryParse(t['$p.TotalBytes']!)?.round() ?? 0;
        used += double.tryParse(t['$p.UsedBytes'] ?? '0')?.round() ?? 0;
        if (j == 0) path = t['$p.Path'] ?? name;
        if ((t['$p.IsError'] ?? 'false').toLowerCase() == 'true') err = true;
      }
      disks.add(StorageDisk(
        name: name,
        path: path,
        state: t['list.info[$i].State'] ?? '',
        totalBytes: total,
        usedBytes: used,
        isError: err,
      ));
    }
    return disks;
  }

  /// Lista as gravações de vídeo entre [from] e [to].
  Future<List<Recording>> findRecordings(DateTime from, DateTime to,
      {int channel = 1}) async {
    final create = await get('/cgi-bin/mediaFileFind.cgi?action=factory.create');
    _check(create);
    final obj = table(create.body)['result'];
    if (obj == null) throw HttpUnavailable('A câmera não abriu a busca de gravações.');
    final out = <Recording>[];
    try {
      final find = await get('/cgi-bin/mediaFileFind.cgi?action=findFile'
          '&object=$obj'
          '&condition.Channel=$channel'
          '&condition.StartTime=${_q(_fmt(from))}'
          '&condition.EndTime=${_q(_fmt(to))}');
      if (!find.ok) return out; // sem gravações nesse período
      for (var page = 0; page < 50; page++) {
        final next = await get(
            '/cgi-bin/mediaFileFind.cgi?action=findNextFile&object=$obj&count=100');
        if (!next.ok) break;
        final t = table(next.body);
        final found = int.tryParse(t['found'] ?? '0') ?? 0;
        for (var i = 0; i < found; i++) {
          final p = 'items[$i]';
          final type = (t['$p.Type'] ?? 'dav').toLowerCase();
          if (type != 'dav' && type != 'mp4') continue;
          final s = _parseTime(t['$p.StartTime']);
          final e = _parseTime(t['$p.EndTime']);
          final path = t['$p.FilePath'];
          if (s == null || e == null || path == null) continue;
          List<String> list(String key) => [
                for (var k = 0; k < 8; k++)
                  if (t['$p.$key[$k]'] != null) t['$p.$key[$k]']!,
              ];
          out.add(Recording(
            start: s,
            end: e,
            filePath: path,
            lengthBytes: int.tryParse(t['$p.Length'] ?? '0') ?? 0,
            events: list('Events'),
            flags: list('Flags'),
          ));
        }
        if (found < 100) break;
      }
    } finally {
      await get('/cgi-bin/mediaFileFind.cgi?action=close&object=$obj')
          .catchError((_) => HttpResult(0, ''));
      await get('/cgi-bin/mediaFileFind.cgi?action=destroy&object=$obj')
          .catchError((_) => HttpResult(0, ''));
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  /// Baixa o arquivo original da gravação (.dav) para [dest].
  Future<void> download(
    Recording rec,
    File dest, {
    void Function(int received, int total)? onProgress,
    bool Function()? cancelled,
    Map<String, String> headers = const {},
    String prefix = '/cgi-bin/RPC_Loadfile',
  }) async {
    final r = await _open('$prefix${rec.filePath}', headers: headers);
    if (r.status != 200) {
      await r.drain();
      _check(HttpResult(r.status, ''));
    }
    final total = r.contentLength ?? 0;
    final sink = dest.openWrite();
    var received = 0;
    try {
      await for (final chunk in r.body) {
        if (cancelled?.call() == true) {
          throw HttpUnavailable('Download cancelado.');
        }
        sink.add(chunk);
        received += chunk.length;
        onProgress?.call(received, total);
      }
    } catch (_) {
      await sink.close();
      if (await dest.exists()) await dest.delete();
      rethrow;
    } finally {
      r.close();
    }
    await sink.close();
  }

  /// Formata (apaga tudo do) cartão. As câmeras Dahua não apagam arquivos
  /// individuais, só o cartão inteiro. Tenta as variantes conhecidas da API.
  Future<void> format(StorageDisk disk) async {
    final candidates = [
      '/cgi-bin/storageDevice.cgi?action=formatPartition&name=${_q(disk.path)}',
      '/cgi-bin/storageDevice.cgi?action=formatPatition&name=${_q(disk.path)}',
      '/cgi-bin/storageDevice.cgi?action=setDevice&type=FormatPatition&path=${_q(disk.path)}',
      '/cgi-bin/storageDevice.cgi?action=formatPartition&name=${_q(disk.name)}',
    ];
    for (final c in candidates) {
      final r = await get(c);
      if (r.status == 401) {
        throw HttpUnavailable('Senha recusada pela API web da câmera.');
      }
      if (r.ok && r.body.trim().toUpperCase().startsWith('OK')) return;
    }
    throw HttpUnavailable(
        'A câmera não aceitou o comando de formatar. Formate pelo Mibo Smart '
        '(configurações da câmera → Armazenamento → Formatar).');
  }
}

/// Resposta HTTP com corpo em fluxo (suporta Content-Length e chunked).
class _OpenResponse {
  final Socket _socket;
  final int status;
  final List<MapEntry<String, String>> _headers;
  final Stream<Uint8List> body;

  _OpenResponse(this._socket, this.status, this._headers, this.body);

  String? header(String name) {
    for (final h in _headers) {
      if (h.key == name) return h.value;
    }
    return null;
  }

  List<String> allHeaders(String name) =>
      [for (final h in _headers) if (h.key == name) h.value];

  int? get contentLength => int.tryParse(header('content-length') ?? '');

  static Future<_OpenResponse> read(Socket socket) async {
    final controller = StreamController<Uint8List>();
    final headerDone = Completer<_OpenResponse>();
    final buf = BytesBuilder(copy: false);
    var headersParsed = false;
    _ChunkDecoder? chunked;
    int? remaining;

    void emit(Uint8List data) {
      if (data.isEmpty) return;
      if (chunked != null) {
        for (final part in chunked!.feed(data)) {
          controller.add(part);
        }
        if (chunked!.done) controller.close();
      } else {
        if (remaining != null) {
          if (data.length > remaining!) data = Uint8List.sublistView(data, 0, remaining!);
          remaining = remaining! - data.length;
        }
        controller.add(data);
        if (remaining == 0 && !controller.isClosed) controller.close();
      }
    }

    late StreamSubscription sub;
    sub = socket.listen((data) {
      if (headersParsed) {
        if (!controller.isClosed) emit(data);
        return;
      }
      buf.add(data);
      final all = buf.toBytes();
      final end = _indexOfCrlf2(all);
      if (end < 0) {
        buf.clear();
        buf.add(all);
        return;
      }
      headersParsed = true;
      final head = latin1.decode(Uint8List.sublistView(all, 0, end));
      final lines = head.split('\r\n');
      final parts = lines.first.split(' ');
      final status = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
      final headers = <MapEntry<String, String>>[];
      for (final l in lines.skip(1)) {
        final i = l.indexOf(':');
        if (i > 0) {
          headers.add(MapEntry(
              l.substring(0, i).trim().toLowerCase(), l.substring(i + 1).trim()));
        }
      }
      String? h(String n) {
        for (final e in headers) {
          if (e.key == n) return e.value;
        }
        return null;
      }

      if ((h('transfer-encoding') ?? '').toLowerCase().contains('chunked')) {
        chunked = _ChunkDecoder();
      } else {
        remaining = int.tryParse(h('content-length') ?? '');
      }
      headerDone.complete(_OpenResponse(socket, status, headers, controller.stream));
      final rest = Uint8List.sublistView(all, end + 4);
      if (remaining == 0) {
        controller.close();
      } else {
        emit(rest);
      }
    }, onDone: () {
      if (!headerDone.isCompleted) {
        headerDone.completeError(
            HttpUnavailable('A câmera fechou a conexão web sem responder.'));
      }
      if (!controller.isClosed) controller.close();
    }, onError: (Object e) {
      if (!headerDone.isCompleted) {
        headerDone.completeError(HttpUnavailable('Erro de rede: $e'));
      }
      if (!controller.isClosed) {
        controller.addError(e);
        controller.close();
      }
    });
    controller.onCancel = () {
      sub.cancel();
      socket.destroy();
    };

    return headerDone.future.timeout(const Duration(seconds: 8), onTimeout: () {
      sub.cancel();
      socket.destroy();
      throw HttpUnavailable('A câmera não respondeu na API web.');
    });
  }

  static int _indexOfCrlf2(Uint8List b) {
    for (var i = 0; i + 3 < b.length; i++) {
      if (b[i] == 13 && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) {
        return i;
      }
    }
    return -1;
  }

  Future<Uint8List> readAll() async {
    final b = BytesBuilder(copy: false);
    await for (final c in body.timeout(const Duration(seconds: 15))) {
      b.add(c);
    }
    close();
    return b.toBytes();
  }

  Future<void> drain() async {
    try {
      await readAll();
    } catch (_) {}
  }

  void close() => _socket.destroy();
}

/// Decodifica Transfer-Encoding: chunked em fluxo.
class _ChunkDecoder {
  final List<int> _pending = [];
  int _need = -1; // -1 = lendo tamanho
  bool done = false;
  bool _skipCrlf = false;

  List<Uint8List> feed(Uint8List data) {
    final out = <Uint8List>[];
    _pending.addAll(data);
    while (!done) {
      if (_skipCrlf) {
        if (_pending.length < 2) break;
        _pending.removeRange(0, 2);
        _skipCrlf = false;
      }
      if (_need < 0) {
        var idx = -1;
        for (var i = 0; i + 1 < _pending.length; i++) {
          if (_pending[i] == 13 && _pending[i + 1] == 10) {
            idx = i;
            break;
          }
        }
        if (idx < 0) break;
        final line = latin1.decode(_pending.sublist(0, idx)).split(';').first.trim();
        _pending.removeRange(0, idx + 2);
        _need = int.tryParse(line, radix: 16) ?? 0;
        if (_need == 0) {
          done = true;
          break;
        }
      }
      if (_pending.isEmpty) break;
      final take = _pending.length < _need ? _pending.length : _need;
      out.add(Uint8List.fromList(_pending.sublist(0, take)));
      _pending.removeRange(0, take);
      _need -= take;
      if (_need == 0) {
        _need = -1;
        _skipCrlf = true;
      }
    }
    return out;
  }
}
