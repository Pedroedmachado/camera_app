import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'config.dart';

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
    for (final c in [_name, _host, _port, _user, _pass, _channel]) {
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
      user: _user.text.trim(),
      password: _pass.text,
      channel: int.parse(_channel.text.trim()),
      hd: _hd,
    );
    await cfg.save();
    if (mounted) Navigator.of(context).pop(true);
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
                      helperText:
                          'Veja no app Mibo Smart (informações da câmera) ou no roteador.',
                    ),
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
