/// dsh_mobile — remote terminal monitor for DeepSeek Harness.
///
/// Speaks the mobile relay protocol (docs/mobile-relay-protocol.md) through a
/// host bridge to the local dsh web. The home page lists saved terminals as
/// cards; tapping one opens the full dsh UI in a WebView (tunneled through
/// the relay). Pairing = QR + PIN.
library;

import 'package:flutter/material.dart';

import 'core/app_state.dart';
import 'pages/home_page.dart';
import 'pages/pairing_page.dart';
import 'pages/webview_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState();
  await state.init();
  runApp(DshMobileApp(state: state));
}

class DshMobileApp extends StatelessWidget {
  const DshMobileApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Harness 远程',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      initialRoute: '/',
      routes: {
        '/': (_) => HomePage(state: state),
        '/pair': (_) => PairingPage(state: state),
        '/remote': (_) => WebviewPage(state: state),
      },
    );
  }
}
