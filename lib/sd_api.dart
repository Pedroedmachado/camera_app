import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'dahua_http.dart';

/// Acesso ao cartão SD, independente do protocolo usado pela câmera.
abstract class SdApi {
  String get label;
  Future<void> connect();
  Future<List<StorageDisk>> storage();
  Future<List<Recording>> findRecordings(DateTime from, DateTime to, {int channel = 1});
  Future<void> download(Recording rec, File dest,
      {void Function(int received, int total)? onProgress, bool Function()? cancelled});
  Future<void> format(StorageDisk disk);

  /// Tenta o protocolo novo (RPC2, igual à interface web) e depois o antigo (CGI).
  static Future<SdApi> open(DahuaHttp http) async {
    final errors = <String>[];
    final rpc = RpcSdApi(http);
    try {
      await rpc.connect();
      return rpc;
    } catch (e) {
      errors.add('RPC2: $e');
    }
    final cgi = CgiSdApi(http);
    try {
      await cgi.connect();
      await cgi.storage(); // confirma que os comandos do cartão funcionam
      return cgi;
    } catch (e) {
      errors.add('CGI: $e');
    }
    throw HttpUnavailable(errors.join('\n'));
  }
}

/// API antiga (cgi-bin). Algumas câmeras respondem 400 para os comandos do cartão.
class CgiSdApi implements SdApi {
  CgiSdApi(this.http);
  final DahuaHttp http;

  @override
  String get label => 'CGI';
  @override
  Future<void> connect() => http.deviceType();
  @override
  Future<List<StorageDisk>> storage() => http.storage();
  @override
  Future<List<Recording>> findRecordings(DateTime from, DateTime to, {int channel = 1}) =>
      http.findRecordings(from, to, channel: channel);
  @override
  Future<void> download(Recording rec, File dest,
          {void Function(int, int)? onProgress, bool Function()? cancelled}) =>
      http.download(rec, dest, onProgress: onProgress, cancelled: cancelled);
  @override
  Future<void> format(StorageDisk disk) => http.format(disk);
}

class RpcError implements Exception {
  final int code;
  final String message;
  RpcError(this.code, this.message);
  @override
  String toString() => message;
}

/// API JSON-RPC (/RPC2), a mesma usada pela página web das câmeras Dahua.
class RpcSdApi implements SdApi {
  RpcSdApi(this.http);
  final DahuaHttp http;

  String _session = '';
  int _id = 1;
  bool _loggedIn = false;

  @override
  String get label => 'RPC2';

  Map<String, String> get _cookie => _session.isEmpty
      ? const {}
      : {
          'Cookie': 'WebClientSessionID=$_session; DWebClientSessionID=$_session; '
              'DhWebClientSessionID=$_session'
        };

  Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> req) async {
    final r = await http.post(path, jsonEncode(req), headers: _cookie);
    if (r.status == 404) {
      throw HttpUnavailable('Esta câmera não tem a API RPC2.');
    }
    if (r.status != 200) {
      throw HttpUnavailable('RPC2 respondeu erro HTTP ${r.status}.');
    }
    final body = r.body.trim();
    try {
      final j = jsonDecode(body);
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    throw HttpUnavailable('Resposta estranha da câmera: '
        '${body.length > 80 ? body.substring(0, 80) : body}');
  }

  static String _md5Upper(String s) =>
      md5.convert(utf8.encode(s)).toString().toUpperCase();

  @override
  Future<void> connect() async {
    if (_loggedIn) return;
    final user = http.user;
    final first = await _send('/RPC2_Login', {
      'method': 'global.login',
      'params': {
        'userName': user,
        'password': '',
        'clientType': 'Web3.0',
        'loginType': 'Direct',
      },
      'id': _id++,
    });
    _session = '${first['session'] ?? ''}';
    final params = (first['params'] as Map?) ?? const {};
    final encryption = '${params['encryption'] ?? 'Default'}';
    final realm = '${params['realm'] ?? ''}';
    final random = '${params['random'] ?? ''}';

    String hashed;
    switch (encryption) {
      case 'Basic':
        hashed = base64.encode(utf8.encode('$user:${http.password}'));
        break;
      case 'Default':
        hashed = _md5Upper('$user:$random:${_md5Upper('$user:$realm:${http.password}')}');
        break;
      default:
        hashed = http.password;
    }

    final second = await _send('/RPC2_Login', {
      'method': 'global.login',
      'params': {
        'userName': user,
        'password': hashed,
        'clientType': 'Web3.0',
        'loginType': encryption == 'WatchNet' ? 'WatchNet' : 'Direct',
        'authorityType': encryption,
      },
      'id': _id++,
      'session': _session,
    });
    if (second['result'] != true) {
      final err = second['error'] as Map?;
      final code = (err?['code'] as num?)?.toInt() ?? 0;
      if (code == 268632071 || code == 268632070) {
        throw HttpUnavailable('Senha recusada pela câmera (login web).');
      }
      if (code == 268632081 || code == 268632073) {
        throw HttpUnavailable(
            'A câmera bloqueou o login por muitas tentativas. Espere 30 minutos.');
      }
      throw HttpUnavailable('Login web recusado (código $code).');
    }
    final newSession = second['session'];
    if (newSession != null && '$newSession'.isNotEmpty) _session = '$newSession';
    _loggedIn = true;
  }

  /// Chama um método RPC2. Devolve a resposta inteira.
  Future<Map<String, dynamic>> call(String method,
      {Object? params, int? object}) async {
    await connect();
    final req = <String, dynamic>{
      'method': method,
      'params': params,
      'id': _id++,
      'session': _session,
    };
    if (object != null) req['object'] = object;
    final res = await _send('/RPC2', req);
    final err = res['error'];
    if (err is Map && res['result'] != true && res['params'] == null) {
      final code = (err['code'] as num?)?.toInt() ?? 0;
      if (code == 28763750 || code == 287637505 || code == 287637504) {
        // Sessão expirou: entra de novo uma vez.
        _loggedIn = false;
        _session = '';
        await connect();
        req['session'] = _session;
        req['id'] = _id++;
        return _send('/RPC2', req);
      }
      throw RpcError(code, '$method falhou (código $code): ${err['message'] ?? ''}');
    }
    return res;
  }

  static int _int(Object? v) {
    if (v is num) return v.toInt();
    return num.tryParse('$v')?.toInt() ?? 0;
  }

  static DateTime? _time(Object? v) {
    final m = RegExp(r'(\d+)-(\d+)-(\d+)[ T](\d+):(\d+):(\d+)').firstMatch('$v');
    if (m == null) return null;
    int g(int i) => int.parse(m.group(i)!);
    return DateTime(g(1), g(2), g(3), g(4), g(5), g(6));
  }

  static String _fmt(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Future<List<StorageDisk>> storage() async {
    List? info;
    try {
      final inst = await call('storage.factory.instance');
      final obj = _int(inst['result']);
      final r = await call('storage.getDeviceAllInfo', object: obj == 0 ? null : obj);
      final p = r['params'];
      info = p is Map ? (p['info'] as List?) : (p is List ? p : null);
    } on RpcError {
      final r = await call('storage.getDeviceAllInfo');
      final p = r['params'];
      info = p is Map ? (p['info'] as List?) : null;
    }
    final out = <StorageDisk>[];
    for (final d in info ?? const []) {
      if (d is! Map) continue;
      var total = 0, used = 0;
      var err = false;
      var path = '${d['Name'] ?? ''}';
      final details = (d['Detail'] as List?) ?? const [];
      for (var i = 0; i < details.length; i++) {
        final x = details[i];
        if (x is! Map) continue;
        total += _int(x['TotalBytes']);
        used += _int(x['UsedBytes']);
        if (x['IsError'] == true) err = true;
        if (i == 0 && x['Path'] != null) path = '${x['Path']}';
      }
      out.add(StorageDisk(
        name: '${d['Name'] ?? path}',
        path: path,
        state: '${d['State'] ?? ''}',
        totalBytes: total,
        usedBytes: used,
        isError: err,
      ));
    }
    return out;
  }

  @override
  Future<List<Recording>> findRecordings(DateTime from, DateTime to,
      {int channel = 1}) async {
    final create = await call('mediaFileFind.factory.create');
    final obj = _int(create['result']);
    if (obj == 0) throw HttpUnavailable('A câmera não abriu a busca de gravações.');
    final out = <Recording>[];
    try {
      Map<String, dynamic> found;
      try {
        found = await call('mediaFileFind.findFile', object: obj, params: {
        'condition': {
          'Channel': channel - 1, // RPC conta canais a partir de 0
          'Dirs': [],
          'Types': ['dav'],
          'Order': 'Ascent',
          'Redundant': 'Exclusion',
          'Events': null,
          'StartTime': _fmt(from),
          'EndTime': _fmt(to),
          'Flags': ['Timing', 'Event', 'Event', 'Manual'],
        },
      });
      } on RpcError {
        return out; // nada nesse período
      }
      if (found['result'] != true) return out; // nada nesse período
      for (var page = 0; page < 50; page++) {
        final next = await call('mediaFileFind.findNextFile',
            object: obj, params: {'count': 100});
        final p = next['params'];
        if (p is! Map) break;
        final infos = (p['infos'] as List?) ?? const [];
        for (final f in infos) {
          if (f is! Map) continue;
          final s = _time(f['StartTime']);
          final e = _time(f['EndTime']);
          final path = f['FilePath'];
          if (s == null || e == null || path == null) continue;
          out.add(Recording(
            start: s,
            end: e,
            filePath: '$path',
            lengthBytes: _int(f['Length']),
            events: [for (final x in (f['Events'] as List?) ?? const []) '$x'],
            flags: [for (final x in (f['Flags'] as List?) ?? const []) '$x'],
          ));
        }
        if (_int(p['found']) < 100) break;
      }
    } finally {
      try {
        await call('mediaFileFind.close', object: obj);
        await call('mediaFileFind.destroy', object: obj);
      } catch (_) {}
    }
    out.sort((a, b) => b.start.compareTo(a.start));
    return out;
  }

  @override
  Future<void> download(Recording rec, File dest,
      {void Function(int, int)? onProgress, bool Function()? cancelled}) async {
    await connect();
    if (!rec.filePath.startsWith('/')) {
      throw HttpUnavailable('Essa gravação não está no cartão local da câmera.');
    }
    try {
      await http.download(rec, dest,
          onProgress: onProgress,
          cancelled: cancelled,
          headers: _cookie,
          prefix: '/RPC_Loadfile');
    } on HttpUnavailable {
      // Algumas versões só aceitam pelo caminho do cgi-bin.
      await http.download(rec, dest,
          onProgress: onProgress, cancelled: cancelled, headers: _cookie);
    }
  }

  @override
  Future<void> format(StorageDisk disk) async {
    final errors = <String>[];
    for (final name in {disk.name, disk.path}) {
      try {
        final inst = await call('devStorage.factory.instance', params: {'name': name});
        final obj = _int(inst['result']);
        if (obj == 0) {
          errors.add('$name: sem acesso');
          continue;
        }
        final r = await call('devStorage.formatPatition',
            object: obj, params: {'part': '', 'fs': ''});
        if (r['result'] == true || r['error'] == null) return;
        errors.add('$name: ${r['error']}');
      } catch (e) {
        errors.add('$name: $e');
      }
    }
    throw HttpUnavailable(
        'A câmera não aceitou formatar (${errors.join('; ')}). '
        'Formate pelo Mibo Smart: configurações da câmera → Armazenamento → Formatar.');
  }
}
