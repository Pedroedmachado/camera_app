import 'package:shared_preferences/shared_preferences.dart';

/// Dados de conexão da câmera. Ficam salvos só no aparelho.
class CameraConfig {
  String name;
  String host;
  int port;
  String user;
  String password;
  int channel;
  bool hd;

  CameraConfig({
    this.name = 'Câmera',
    this.host = '',
    this.port = 554,
    this.user = 'admin',
    this.password = '',
    this.channel = 1,
    this.hd = true,
  });

  bool get isComplete => host.trim().isNotEmpty && password.isNotEmpty;

  /// URL RTSP no padrão das câmeras Mibo (base Dahua).
  /// subtype=0 → stream principal (HD), subtype=1 → stream extra (SD).
  String rtspPath({bool? hd}) {
    final sub = (hd ?? this.hd) ? 0 : 1;
    return '/cam/realmonitor?channel=$channel&subtype=$sub';
  }

  String rtspUrl({bool? hd, bool hidePassword = false}) {
    final u = Uri.encodeComponent(user);
    final p = hidePassword ? '****' : Uri.encodeComponent(password);
    return 'rtsp://$u:$p@${host.trim()}:$port${rtspPath(hd: hd)}';
  }

  static Future<CameraConfig> load() async {
    final sp = await SharedPreferences.getInstance();
    return CameraConfig(
      name: sp.getString('name') ?? 'Câmera',
      host: sp.getString('host') ?? '',
      port: sp.getInt('port') ?? 554,
      user: sp.getString('user') ?? 'admin',
      password: sp.getString('password') ?? '',
      channel: sp.getInt('channel') ?? 1,
      hd: sp.getBool('hd') ?? true,
    );
  }

  Future<void> save() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('name', name);
    await sp.setString('host', host.trim());
    await sp.setInt('port', port);
    await sp.setString('user', user);
    await sp.setString('password', password);
    await sp.setInt('channel', channel);
    await sp.setBool('hd', hd);
  }
}
