import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Resultado do teste direto na câmera (sem o player).
class ProbeResult {
  final bool ok;
  final String message;
  final String? video; // ex.: H264, H265
  final String? audio; // ex.: PCMA, MPEG4-GENERIC
  ProbeResult(this.ok, this.message, {this.video, this.audio});
}

class RtspResponse {
  final int status;
  final Map<String, String> headers;
  final String body;
  RtspResponse(this.status, this.headers, this.body);
}

/// Faz um DESCRIBE RTSP com autenticação Digest/Basic, igual a um player,
/// para dizer exatamente o que a câmera respondeu.
class RtspProbe {
  static Future<ProbeResult> run({
    required String host,
    required int port,
    required String user,
    required String password,
    required String path,
  }) async {
    final uri = 'rtsp://$host:$port$path';
    Socket socket;
    try {
      socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 4));
    } catch (_) {
      return ProbeResult(false,
          'Não consegui conectar em $host:$port. Confira o IP, a porta RTSP e se está no mesmo Wi-Fi.');
    }

    final reader = RtspReader(socket);
    try {
      var cseq = 1;
      socket.write(_req('DESCRIBE', uri, cseq++, null));
      var res = await reader.next();
      if (res == null) {
        return ProbeResult(false, 'A câmera aceitou a conexão mas não respondeu ao RTSP.');
      }

      if (res.status == 401) {
        final challenge = res.headers['www-authenticate'] ?? '';
        final auth = authHeader(challenge, 'DESCRIBE', uri, user, password);
        if (auth == null) {
          return ProbeResult(false, 'A câmera pediu um tipo de login desconhecido: $challenge');
        }
        socket.write(_req('DESCRIBE', uri, cseq++, auth));
        res = await reader.next();
        if (res == null) {
          return ProbeResult(false, 'A câmera fechou a conexão depois do login.');
        }
      }

      switch (res.status) {
        case 200:
          final v = codec(res.body, 'video');
          final a = codec(res.body, 'audio');
          return ProbeResult(
            true,
            'Senha OK. A câmera liberou o vídeo'
            '${v != null ? ' ($v' : ''}${a != null ? ', áudio $a' : ''}${v != null ? ')' : ''}.',
            video: v,
            audio: a,
          );
        case 401:
          return ProbeResult(false,
              'Senha errada. Use a chave de acesso NOVA (a que você definiu ao vincular no Mibo Smart). Usuário: admin.');
        case 403:
          return ProbeResult(false,
              'A câmera recusou o acesso (403). Pode estar bloqueada por muitas tentativas: espere 30 minutos ou reinicie a câmera.');
        case 404:
          return ProbeResult(false, 'A câmera não reconhece esse caminho de vídeo (404). Confira o canal.');
        default:
          return ProbeResult(false, 'A câmera respondeu com erro ${res.status}.');
      }
    } on TimeoutException {
      return ProbeResult(false, 'A câmera demorou demais para responder.');
    } catch (e) {
      return ProbeResult(false, 'Erro no teste: $e');
    } finally {
      socket.destroy();
    }
  }

  static String _req(String method, String uri, int cseq, String? auth) {
    final b = StringBuffer()
      ..write('$method $uri RTSP/1.0\r\n')
      ..write('CSeq: $cseq\r\n')
      ..write('User-Agent: CamLivre\r\n')
      ..write('Accept: application/sdp\r\n');
    if (auth != null) b.write('Authorization: $auth\r\n');
    b.write('\r\n');
    return b.toString();
  }

  static String _md5(String s) => md5.convert(utf8.encode(s)).toString();

  static String? authHeader(
      String challenge, String method, String uri, String user, String pass) {
    final lower = challenge.toLowerCase();
    if (lower.startsWith('basic')) {
      return 'Basic ${base64.encode(utf8.encode('$user:$pass'))}';
    }
    if (!lower.startsWith('digest')) return null;
    final params = <String, String>{};
    final re = RegExp(r'(\w+)\s*=\s*(?:"([^"]*)"|([^,\s]+))');
    for (final m in re.allMatches(challenge.substring(6))) {
      params[m.group(1)!.toLowerCase()] = m.group(2) ?? m.group(3) ?? '';
    }
    final realm = params['realm'] ?? '';
    final nonce = params['nonce'] ?? '';
    final ha1 = _md5('$user:$realm:$pass');
    final ha2 = _md5('$method:$uri');
    final qop = params['qop'];
    if (qop != null && qop.split(',').map((e) => e.trim()).contains('auth')) {
      const nc = '00000001';
      final cnonce = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      final resp = _md5('$ha1:$nonce:$nc:$cnonce:auth:$ha2');
      return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", '
          'response="$resp", qop=auth, nc=$nc, cnonce="$cnonce"';
    }
    final resp = _md5('$ha1:$nonce:$ha2');
    return 'Digest username="$user", realm="$realm", nonce="$nonce", uri="$uri", response="$resp"';
  }

  /// Lê o codec da seção m=video / m=audio do SDP.
  static String? codec(String sdp, String kind) {
    String? section;
    for (final raw in const LineSplitter().convert(sdp)) {
      final line = raw.trim();
      if (line.startsWith('m=')) section = line.substring(2).split(' ').first;
      if (section == kind && line.startsWith('a=rtpmap:')) {
        final parts = line.split(' ');
        if (parts.length > 1) return parts[1].split('/').first.toUpperCase();
      }
    }
    return null;
  }
}

/// Junta os bytes do socket e entrega uma resposta RTSP completa por vez.
class RtspReader {
  final List<int> _buf = [];
  final _waiters = <Completer<void>>[];
  bool _closed = false;

  /// Depois do PLAY a câmera pode mandar dados binários; descarta tudo.
  bool discard = false;
  bool get closed => _closed;

  RtspReader(Socket s) {
    s.listen((Uint8List data) {
      if (discard) return;
      _buf.addAll(data);
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    }, onError: (_) {
      _closed = true;
      _wake();
    });
  }

  void _wake() {
    for (final w in List.of(_waiters)) {
      if (!w.isCompleted) w.complete();
    }
    _waiters.clear();
  }

  Future<void> _more() {
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  Future<RtspResponse?> next() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (true) {
      final text = latin1.decode(_buf, allowInvalid: true);
      final end = text.indexOf('\r\n\r\n');
      if (end >= 0) {
        final head = text.substring(0, end);
        final lines = head.split('\r\n');
        final headers = <String, String>{};
        for (final l in lines.skip(1)) {
          final i = l.indexOf(':');
          if (i > 0) {
            headers[l.substring(0, i).trim().toLowerCase()] =
                l.substring(i + 1).trim();
          }
        }
        final len = int.tryParse(headers['content-length'] ?? '0') ?? 0;
        final total = end + 4 + len;
        if (_buf.length >= total) {
          final body = latin1.decode(_buf.sublist(end + 4, total), allowInvalid: true);
          _buf.removeRange(0, total);
          final parts = lines.first.split(' ');
          final status = parts.length > 1 ? int.tryParse(parts[1]) ?? 0 : 0;
          return RtspResponse(status, headers, body);
        }
      }
      if (_closed) return null;
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('rtsp');
      await _more().timeout(left, onTimeout: () {});
    }
  }
}
