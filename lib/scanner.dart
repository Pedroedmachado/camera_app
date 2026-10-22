import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// Um aparelho encontrado na rede local com porta de câmera aberta.
class FoundDevice {
  final String ip;
  final bool rtsp; // porta 554
  final bool dahua; // porta 37777 (protocolo das câmeras Mibo/Dahua)
  final String? server; // cabeçalho "Server" da resposta RTSP
  FoundDevice(this.ip, {required this.rtsp, required this.dahua, this.server});

  /// Tem as duas portas típicas da Mibo: quase certamente a câmera.
  bool get likelyCamera => rtsp && dahua;
}

/// Procura câmeras varrendo a rede local (/24) do aparelho.
class CameraScanner {
  /// Redes IPv4 privadas deste aparelho, ex.: "192.168.0".
  static Future<List<String>> localPrefixes() async {
    final prefixes = <String>{};
    final ifaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    for (final iface in ifaces) {
      for (final a in iface.addresses) {
        final parts = a.address.split('.');
        if (parts.length != 4) continue;
        final p0 = int.tryParse(parts[0]) ?? 0;
        final p1 = int.tryParse(parts[1]) ?? 0;
        final private = p0 == 10 ||
            (p0 == 192 && p1 == 168) ||
            (p0 == 172 && p1 >= 16 && p1 <= 31);
        if (private) prefixes.add('${parts[0]}.${parts[1]}.${parts[2]}');
      }
    }
    return prefixes.toList();
  }

  static Future<bool> _open(String ip, int port, Duration timeout) async {
    try {
      final s = await Socket.connect(ip, port, timeout: timeout);
      s.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pergunta ao servidor RTSP quem ele é (sem senha; só OPTIONS).
  static Future<String?> _rtspServer(String ip) async {
    Socket? s;
    try {
      s = await Socket.connect(ip, 554, timeout: const Duration(seconds: 2));
      s.write('OPTIONS rtsp://$ip:554/ RTSP/1.0\r\nCSeq: 1\r\nUser-Agent: CamLivre\r\n\r\n');
      // A câmera não fecha a conexão: lê só a primeira resposta.
      final List<int> data = await s.first
          .timeout(const Duration(seconds: 2), onTimeout: () => Uint8List(0));
      final text = String.fromCharCodes(data);
      for (final line in text.split('\r\n')) {
        if (line.toLowerCase().startsWith('server:')) {
          return line.substring(7).trim();
        }
      }
      return text.startsWith('RTSP/') ? 'RTSP' : null;
    } catch (_) {
      return null;
    } finally {
      s?.destroy();
    }
  }

  /// Varre todos os IPs. [onProgress] recebe (feitos, total).
  static Future<List<FoundDevice>> scan({
    void Function(int done, int total)? onProgress,
  }) async {
    final prefixes = await localPrefixes();
    final ips = <String>[
      for (final p in prefixes)
        for (var i = 1; i < 255; i++) '$p.$i',
    ];
    final found = <FoundDevice>[];
    const timeout = Duration(milliseconds: 600);
    const batch = 64;
    var done = 0;
    for (var i = 0; i < ips.length; i += batch) {
      final chunk = ips.sublist(i, (i + batch).clamp(0, ips.length));
      await Future.wait(chunk.map((ip) async {
        final rtsp = await _open(ip, 554, timeout);
        final dahua = await _open(ip, 37777, timeout);
        if (rtsp || dahua) {
          final server = rtsp ? await _rtspServer(ip) : null;
          found.add(FoundDevice(ip, rtsp: rtsp, dahua: dahua, server: server));
        }
        done++;
        onProgress?.call(done, ips.length);
      }));
    }
    found.sort((a, b) {
      if (a.likelyCamera != b.likelyCamera) return a.likelyCamera ? -1 : 1;
      return a.ip.compareTo(b.ip);
    });
    return found;
  }
}
