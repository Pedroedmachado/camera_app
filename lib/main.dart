import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'live_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  runApp(const CamLivreApp());
}

class CamLivreApp extends StatelessWidget {
  const CamLivreApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CamLivre',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: const Color(0xFF00A86B),
      ),
      home: const LivePage(),
    );
  }
}
