import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';
import 'scanner.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _httpPort = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();
  final _channel = TextEditingController();
  bool _hd = true;
  bool _showPass = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    CameraConfig.load().then((c) {
      if (!mounted) return;
      setState(() {
        _name.text = c.name;
        _host.text = c.host;
        _port.text = c.port.toString();
        _httpPort.text = c.httpPort.toString();
        _user.text = c.user;
        _pass.text = c.password;
        _channel.text = c.channel.toString();
        _hd = c.hd;
        _loaded = true;
      });
    });
  }

  @override
  void dispose() {
    for (final c in [_name, _host, _port, _httpPort, _user, _pass, _channel]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    final cfg = CameraConfig(
      name: _name.text.trim().isEmpty ? 'Câmera' : _name.text.trim(),
      host: _host.text.trim(),
      port: int.parse(_port.text.trim()),
      httpPort: int.parse(_httpPort.text.trim()),
      user: _user.text.trim(),
      password: _pass.text,
      channel: int.parse(_channel.text.trim()),
      hd: _hd,
    );
    await cfg.save();
    if (mounted) Navigator.of(context).pop(true);
  }

  Future<void> _scan() async {
    final picked = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _ScanDialog(),
    );
    if (picked != null && mounted) {
      setState(() => _host.text = picked);
    }
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Obrigatório' : null;

  String? _number(String? v) {
    final n = int.tryParse((v ?? '').trim());
    return (n == null || n <= 0) ? 'Número inválido' : null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Configurações')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _form,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(
                      labelText: 'Nome da câmera',
                      hintText: 'Sala, Quarto...',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _host,
                    validator: _required,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(
                      labelText: 'IP da câmera',
                      hintText: '192.168.0.50',
                      helperText: 'Use o botão abaixo para achar automaticamente.',
                    ),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _scan,
                    icon: const Icon(Icons.radar),
                    label: const Text('Procurar câmera na rede'),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _pass,
                    validator: _required,
                    obscureText: !_showPass,
                    decoration: InputDecoration(
                      labelText: 'Senha (chave de acesso)',
                      helperText:
                          'É a chave de acesso da etiqueta, ou a nova se você trocou.',
                      suffixIcon: IconButton(
                        icon: Icon(
                            _showPass ? Icons.visibility_off : Icons.visibility),
                        onPressed: () => setState(() => _showPass = !_showPass),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Abrir em HD'),
                    subtitle: const Text('Desligado = SD, mais leve fora do Wi-Fi bom'),
                    value: _hd,
                    onChanged: (v) => setState(() => _hd = v),
                  ),
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Avançado'),
                    children: [
                      TextFormField(
                        controller: _user,
                        validator: _required,
                        decoration: const InputDecoration(labelText: 'Usuário'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _port,
                        validator: _number,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration:
                            const InputDecoration(labelText: 'Porta RTSP'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _httpPort,
                        validator: _number,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(
                            labelText: 'Porta web (cartão SD)'),
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: _channel,
                        validator: _number,
                        keyboardType: TextInputType.number,
                        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                        decoration: const InputDecoration(labelText: 'Canal'),
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.check),
                    label: const Text('Salvar e conectar'),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    'O celular ou PC precisa estar no mesmo Wi-Fi da câmera. '
                    'Os dados ficam salvos só neste aparelho.',
                    style: TextStyle(color: Colors.white60, fontSize: 12),
                  ),
                ],
              ),
            ),
    );
  }
}

/// Janela que varre a rede e lista o que parece ser câmera.
class _ScanDialog extends StatefulWidget {
  const _ScanDialog();

  @override
  State<_ScanDialog> createState() => _ScanDialogState();
}

class _ScanDialogState extends State<_ScanDialog> {
  int _done = 0;
  int _total = 0;
  bool _finished = false;
  List<FoundDevice> _found = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    try {
      final result = await CameraScanner.scan(onProgress: (d, t) {
        if (mounted) {
          setState(() {
            _done = d;
            _total = t;
          });
        }
      });
      if (!mounted) return;
      setState(() {
        _found = result;
        _finished = true;
        if (_total == 0) {
          _error = 'Este aparelho não está conectado a nenhuma rede local.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Erro ao procurar: $e';
        _finished = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (!_finished) {
      body = Column(mainAxisSize: MainAxisSize.min, children: [
        LinearProgressIndicator(value: _total == 0 ? null : _done / _total),
        const SizedBox(height: 12),
        Text(_total == 0 ? 'Começando…' : 'Verificando $_done de $_total endereços…'),
      ]);
    } else if (_error != null) {
      body = Text(_error!);
    } else if (_found.isEmpty) {
      body = const Text(
        'Nenhuma câmera encontrada.\n\n'
        '• Confira se este aparelho está no mesmo Wi-Fi da câmera.\n'
        '• A luz da câmera precisa estar verde fixa (conectada ao Wi-Fi).\n'
        '• Se a câmera nunca foi ligada ao Wi-Fi, ela ainda não está na rede.',
      );
    } else {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final d in _found)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                d.likelyCamera ? Icons.videocam : Icons.device_unknown,
                color: d.likelyCamera ? Colors.greenAccent : null,
              ),
              title: Text(d.ip),
              subtitle: Text([
                if (d.likelyCamera) 'Provavelmente a câmera',
                if (d.rtsp) 'vídeo (554)',
                if (d.dahua) 'controle (37777)',
                if (d.server != null) d.server!,
              ].join(' · ')),
              onTap: () => Navigator.pop(context, d.ip),
            ),
        ],
      );
    }
    return AlertDialog(
      title: const Text('Procurar câmera'),
      content: SingleChildScrollView(child: body),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(_finished ? 'Fechar' : 'Cancelar'),
        ),
      ],
    );
  }
}
