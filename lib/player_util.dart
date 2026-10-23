import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Define uma propriedade do mpv (Android e Windows).
Future<void> mpvSet(Player player, String key, String value) async {
  final dynamic platform = player.platform;
  try {
    await platform.setProperty(key, value);
  } catch (e) {
    debugPrint('mpv $key=$value falhou: $e');
  }
}

/// Modo RTSP que funcionou na tela ao vivo (tcp/udp/http).
Future<String> savedTransport() async {
  final sp = await SharedPreferences.getInstance();
  return sp.getString('transport') ?? 'tcp';
}

/// Ajustes de baixa latência para RTSP.
Future<void> prepareRtsp(Player player, String transport) async {
  await mpvSet(player, 'rtsp-transport', transport);
  await mpvSet(player, 'cache', 'no');
  await mpvSet(player, 'network-timeout', '15');
}

String formatBytes(int b) {
  if (b <= 0) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = b.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i <= 1 ? 0 : 1).replaceAll('.', ',')} ${units[i]}';
}

String two(int v) => v.toString().padLeft(2, '0');
String hms(DateTime t) => '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
String dmy(DateTime t) => '${two(t.day)}/${two(t.month)}/${t.year}';

String formatDuration(Duration d) {
  if (d.inHours > 0) return '${d.inHours}h ${two(d.inMinutes % 60)}min';
  if (d.inMinutes > 0) return '${d.inMinutes} min ${two(d.inSeconds % 60)}s';
  return '${d.inSeconds}s';
}
