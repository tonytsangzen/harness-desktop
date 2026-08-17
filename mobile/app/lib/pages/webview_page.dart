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
import '../core/foreground_service.dart';
import '../core/lan_backend.dart';
import '../core/p2p_client.dart';
import '../core/relay_client.dart';
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
  /// In-flight P2P upgrade attempt (before the data channel opens), so a
  /// block/unblock race can't leave two channels fighting over the proxy.
  P2pClient? _p2pConnecting;
  /// The relay tunnel backend the page started on; P2P may take over, and the
  /// "block P2P" switch falls back to it.
  RelayClient? _relayClient;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    // Keep the tunnel alive when the UI goes to the background (foreground
    // service on Android); stop it again when the page is disposed.
    await ForegroundService.start();
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
    _relayClient = relayClient;

    // 1) Load through the relay tunnel immediately (no waiting).
    _launchWith(relayClient);

    // 2) In the background, try to upgrade to a direct WebRTC data channel
    //    (signaling rides the relay tunnel). On success the proxy's backend
    //    switches live; on close it falls back to the tunnel. Skipped when
    //    the user blocked P2P (its round-trips can be slower than the tunnel).
    _tryUpgradeToP2P();
  }

  /// Attempt the relay-tunnel → WebRTC P2P upgrade, unless the user blocked
  /// P2P or an upgrade is already in flight / active.
  void _tryUpgradeToP2P() {
    final relayClient = _relayClient;
    if (relayClient == null || _p2p != null || _p2pConnecting != null) return;
    if (widget.state.blockP2P) {
      print('[dsh] P2P blocked by user setting, staying on relay tunnel');
      return;
    }
    final p2p = P2pClient(relayClient);
    _p2pConnecting = p2p;
    p2p.onClosed = () {
      if (mounted && _proxy != null && _p2p == p2p) {
        print('[dsh] P2P closed, falling back to relay tunnel');
        _proxy!.useBackend(relayClient);
        _p2p = null;
      }
      p2p.dispose();
    };
    p2p.connect().then((ok) {
      if (_p2pConnecting == p2p) _p2pConnecting = null;
      // Re-check the block flag: the user may have blocked P2P while the
      // offer/answer was in flight — then don't activate the channel.
      if (ok && mounted && _proxy != null && !widget.state.blockP2P) {
        print('[dsh] P2P data channel active, upgraded backend');
        _proxy!.useBackend(p2p);
        _p2p = p2p;
      } else {
        p2p.dispose();
      }
    }).catchError((Object e) {
      if (_p2pConnecting == p2p) _p2pConnecting = null;
      p2p.dispose();
    });
  }

  /// Apply the "block P2P" switch live: when blocking, drop any active P2P
  /// channel (and any in-flight upgrade) and fall back to the relay tunnel
  /// now; when un-blocking, retry the upgrade. The setting itself is persisted
  /// by [AppState.setBlockP2P].
  Future<void> _setP2pBlocked(bool blocked) async {
    await widget.state.setBlockP2P(blocked);
    if (!mounted) return;
    if (blocked) {
      final connecting = _p2pConnecting;
      _p2pConnecting = null;
      connecting?.dispose();
      final p2p = _p2p;
      _p2p = null;
      p2p?.dispose();
      final relay = _relayClient;
      if (relay != null && _proxy != null) {
        print('[dsh] P2P blocked, backend switched to relay tunnel');
        _proxy!.useBackend(relay);
      }
    } else {
      _tryUpgradeToP2P();
    }
    if (mounted) setState(() {});
  }

  /// Bottom sheet from the connection chip: show the current backend and the
  /// "block P2P" switch (takes effect immediately, persisted).
  Future<void> _showConnectionSheet() async {
    var blocked = widget.state.blockP2P;
    await showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('连接方式', style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  _p2p != null ? '当前：P2P 直连' : '当前：中继隧道',
                  style: Theme.of(ctx).textTheme.bodySmall,
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  secondary: const Icon(Icons.wifi_tethering_off),
                  title: const Text('屏蔽 P2P 直连'),
                  subtitle: const Text('始终走中继隧道；P2P 直连响应慢时建议开启'),
                  value: blocked,
                  onChanged: (v) {
                    setSheetState(() => blocked = v);
                    _setP2pBlocked(v);
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Small floating chip over the WebView showing which backend is active;
  /// tapping it opens the connection / "block P2P" sheet. Hidden in LAN mode.
  Widget _buildConnectionChip() {
    if (_lanMode || _proxy == null) return const SizedBox.shrink();
    final p2pActive = _p2p != null;
    final color = p2pActive ? Colors.indigo : Colors.blueGrey;
    return Material(
      color: color,
      elevation: 3,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _showConnectionSheet,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                p2pActive ? Icons.wifi_tethering : Icons.cloud,
                size: 16,
                color: Colors.white,
              ),
              const SizedBox(width: 6),
              Text(
                p2pActive ? 'P2P 直连' : '中继隧道',
                style: const TextStyle(color: Colors.white, fontSize: 12),
              ),
              const SizedBox(width: 4),
              const Icon(Icons.tune, size: 14, color: Colors.white70),
            ],
          ),
        ),
      ),
    );
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
    ForegroundService.stop();
    _proxy?.close();
    _lanBackend?.dispose();
    _p2pConnecting?.dispose();
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
                  child: Stack(
                    children: [
                      WebViewWidget(controller: _controller!),
                      // Floating connection chip (relay tunnel / P2P direct);
                      // tap to block or re-enable P2P.
                      Positioned(
                        top: 8,
                        right: 8,
                        child: _buildConnectionChip(),
                      ),
                    ],
                  ),
                ),
    );
  }
}
