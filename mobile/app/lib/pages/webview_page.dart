/// Full dsh web UI in a WebView.
///
/// Preferred path: when the pairing QR carried a LAN address ("ip:port") and
/// the desktop's dsh web answers on the LAN, the WebView loads it directly
/// (same-origin, no tunnel). Otherwise a local [WebProxy] fronts the relay
/// tunnel: the WebView loads `http://127.0.0.1:<port>/` and all traffic
/// (page, assets, /api RPC, /api/events.mux WebSocket) flows
/// phone → relay → bridge → desktop dsh. If the LAN path fails mid-session
/// (e.g. the desktop moved networks), the page falls back to the tunnel.
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/app_state.dart';
import '../core/lan_backend.dart';
import '../core/p2p_client.dart';
import '../core/tunnel_backend.dart';
import '../core/web_proxy.dart';

class WebviewPage extends StatefulWidget {
  const WebviewPage({super.key, required this.state});
  final AppState state;

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> {
  WebProxy? _proxy;
  WebViewController? _controller;
  String? _error;
  bool _lanMode = false; // currently loading the desktop directly on the LAN
  bool _fellBack = false; // already fell back from LAN to the relay tunnel
  P2pClient? _p2p;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final lan = widget.state.currentConnection?.lan;
    if (lan != null && await AppState.lanAvailable(lan)) {
      _lanMode = true;
      // LAN-direct mode still routes through the local proxy so the WebView
      // origin is always 127.0.0.1:<fixed port> — dsh's localStorage session
      // history then survives mode switches and restarts.
      print('[dsh] LAN mode via proxy, backend=$lan');
      final backend = LanBackend(lan);
      _lanBackend = backend;
      _launchWith(backend);
      return;
    }
    _startTunnel();
  }

  void _startTunnel() {
    final client = widget.state.client;
    if (client == null) {
      if (mounted) setState(() => _error = '未连接');
      return;
    }
    final relayClient = client;

    // 1) Load through the relay tunnel immediately (no waiting).
    _launchWith(relayClient);

    // 2) In the background, try to upgrade to a direct WebRTC data channel
    //    (signaling rides the relay tunnel). On success the proxy's backend
    //    switches live; on close it falls back to the tunnel.
    final p2p = P2pClient(relayClient);
    p2p.onClosed = () {
      if (mounted && _proxy != null && _p2p == p2p) {
        print('[dsh] P2P closed, falling back to relay tunnel');
        _proxy!.useBackend(relayClient);
        _p2p = null;
      }
      p2p.dispose();
    };
    p2p.connect().then((ok) {
      if (ok && mounted && _proxy != null) {
        print('[dsh] P2P data channel active, upgraded backend');
        _proxy!.useBackend(p2p);
        _p2p = p2p;
      } else {
        p2p.dispose();
      }
    }).catchError((Object e) {
      p2p.dispose();
    });
  }

  void _launchWith(TunnelBackend backend) {
    final proxy = WebProxy(backend);
    _proxy = proxy;
    proxy.start().then((_) {
      if (!mounted) return;
      final controller = _buildController();
      _controller = controller;
      setState(() {});
      controller.loadRequest(Uri.parse('http://127.0.0.1:${proxy.port}/'));
    }).catchError((Object e) {
      if (mounted) setState(() => _error = '启动本地代理失败: $e');
    });
  }

  WebViewController _buildController() {
    return WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..setOnConsoleMessage((message) {
        print('[webview] ${message.level}: ${message.message}');
      })
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (_error != null && mounted) setState(() => _error = null);
            _shrinkToFitDesktop();
            _restoreActiveSession();
            _retryFailedPlugins();
            if (mounted) setState(() {});
          },
          onWebResourceError: (err) {
            print('[webview] resource error: ${err.errorCode} ${err.description} url=${err.url} main=${err.isForMainFrame}');
            // The tunnel fails with 502 when the desktop host is offline —
            // show a clear message instead of a blank page. A failing direct
            // LAN load falls back to the relay tunnel first.
            if (err.isForMainFrame == true && mounted) {
              if (_lanMode && !_fellBack) {
                _fellBack = true;
                _lanMode = false;
                _proxy?.close();
                _proxy = null;
                _startTunnel();
              } else {
                setState(() => _error = '无法加载电脑端页面。\n请确认电脑上的 Harness 已打开，然后重试。');
              }
            }
          },
        ),
      );
  }

  @override
  void dispose() {
    _proxy?.close();
    _lanBackend?.dispose();
    _p2p?.dispose();
    widget.state.disconnect();    super.dispose();
  }

  /// The dsh UI is a desktop layout; on a phone viewport it renders squeezed
  /// with oversized text. Zooming the root element shrinks everything so the
  /// full desktop layout (sidebar + main area) fits the screen with smaller
  /// text, mirroring the desktop experience.
  void _shrinkToFitDesktop() {
    final c = _controller;
    if (c == null) return;
    c.runJavaScript('''
      (function () {
        try {
          var el = document.documentElement;
          var zoom = 0.6;
          if (el) {
            el.style.setProperty('zoom', String(zoom));
            el.style.setProperty('min-height', '100%');
          }
        } catch (e) { /* ignore */ }
      })();
    ''');
  }

  void _retry() {
    setState(() => _error = null);
    _controller?.reload();
  }

  bool _restoringSession = false;
  int _restoreAttempts = 0;
  int _pluginRetries = 0;
  LanBackend? _lanBackend;

  /// dsh remembers the current session in localStorage (`dsh.sessions.current`).
  /// A fresh WebView has empty storage, so the frontend would open a brand-new
  /// session. Restore the desktop's currently active session by writing that
  /// key and reloading once — after the reload the frontend reads it and
  /// opens the active conversation instead of a new one.
  Future<void> _restoreActiveSession() async {
    final c = _controller;
    if (c == null || _restoringSession) return;
    _restoringSession = true;
    try {
      final sid = await widget.state.activeSessionId();
      if (sid == null || sid.isEmpty) return;
      final current = await c
          .runJavaScriptReturningResult('localStorage.getItem("dsh.sessions.current")');
      if (current is String && current.contains(sid)) return; // already there
      if (_restoreAttempts >= 2) return; // never loop forever
      _restoreAttempts++;
      await c.runJavaScript(
          'localStorage.setItem("dsh.sessions.current", JSON.stringify({sessionId: "$sid"}))');
      await c.reload();
    } catch (e) {
      print('[dsh] restore error: $e');
    } finally {
      _restoringSession = false;
    }
  }

  /// dsh renders "Failed to load plugins" when a plugin bundle script failed
  /// to load (e.g. the desktop was mid-restart). Reload a few times so a
  /// transient 502 doesn't leave the user stuck on the error page.
  Future<void> _retryFailedPlugins() async {
    if (_pluginRetries >= 3) return;
    final c = _controller;
    if (c == null) return;
    await Future.delayed(const Duration(seconds: 4));
    try {
      final t = await c
          .runJavaScriptReturningResult('document.body ? document.body.innerText.slice(0, 200) : ""');
      if (t is String && t.contains('Failed to load plugins')) {
        _pluginRetries++;
        await c.reload();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          : _controller == null
              ? const Center(child: CircularProgressIndicator())
              : SafeArea(
                  // Keep the web view below the system status bar / notch.
                  child: WebViewWidget(controller: _controller!),
                ),
    );
  }
}
