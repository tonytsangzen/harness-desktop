/// Full dsh web UI in a WebView.
///
/// Preferred path: when the pairing QR carried a LAN address ("ip:port") and
/// the desktop's dsh web answers on the LAN, the WebView loads it directly
/// (same-origin, no tunnel). Otherwise a local [WebProxy] fronts the relay
/// tunnel: the WebView loads `http://127.0.0.1:<port>/` and all traffic
/// (page, assets, HTTP, WebSocket) flows phone → relay → bridge → desktop dsh.
/// If the LAN path fails mid-session
/// (e.g. the desktop moved networks), the page falls back to the tunnel.
///
/// All non-LAN traffic goes through the relay tunnel.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../core/app_state.dart';
import '../core/foreground_service.dart';
import '../core/lan_backend.dart';
import '../core/tunnel_backend.dart';
import '../core/web_proxy.dart';

class WebviewPage extends StatefulWidget {
  const WebviewPage({super.key, required this.state});
  final AppState state;

  @override
  State<WebviewPage> createState() => _WebviewPageState();
}

class _WebviewPageState extends State<WebviewPage> with WidgetsBindingObserver {
  WebProxy? _proxy;
  PortBackend? _proxyBackend; // the backend the running proxy dials through
  WebViewController? _controller;
  String? _error;
  bool _lanMode = false; // currently loading the desktop directly on the LAN
  bool _fellBack = false; // already fell back from LAN to the relay tunnel
  bool _wasOnline = true; // last observed tunnel status (for edge detection)

  // Long-session rendering recovery. Hours of WebView uptime (lock/unlock
  // cycles in between, memory pressure from other apps) can kill the web
  // content/renderer process or corrupt the compositor surface; the page then
  // sits there garbled or frozen forever. The platform APIs for this are not
  // uniformly exposed (iOS surfaces it as a main-frame resource error,
  // Android's onRenderProcessGone is missing from the plugin entirely), so
  // the watchdog below probes the page and escalates on failure.
  static const int _webContentProcessTerminatedCode = 2; // WKErrorCode, iOS
  Timer? _probeTimer;
  bool _probing = false; // one probe at a time
  bool _pageReady = false; // first page finished loading on this controller
  int _probeFailures = 0; // consecutive failed renderer probes
  int _recoveries = 0; // automatic recoveries since the last successful load
  int _generation = 0; // bumped per platform-view rebuild (fresh surface)
  DateTime? _lastManualRefresh;

  @override
  void initState() {
    super.initState();
    // Immersive fullscreen for the remote view: status/navigation bars hide,
    // a swipe from the edge reveals them temporarily (sticky).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WidgetsBinding.instance.addObserver(this);
    _wasOnline = widget.state.connected;
    widget.state.addListener(_onStateChanged);
    _probeTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _probeAndRecover();
    });
    _bootstrap();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Screen unlocked / app back in foreground: the tunnel likely died while
    // locked — skip the remaining backoff and reconnect right away. The
    // renderer is the usual casualty of background time, so also probe it
    // now instead of making the user stare at a garbled page for a minute.
    if (state == AppLifecycleState.resumed) {
      widget.state.resumeReconnect();
      _probeAndRecover();
    }
  }

  void _onStateChanged() {
    final online = widget.state.connected;
    // The relay tunnel just came back: reload so the page recovers from the
    // requests that failed while it was down.
    if (online && !_wasOnline && !_lanMode && _controller != null) {
      _onTunnelRestored();
    }
    _wasOnline = online;
    if (mounted) setState(() {});
  }

  Uri _appUrl(int proxyPort) {
    // No launch token here: the bridge injects it into the first `GET /` of
    // each stream (it rotates on every dsh restart, so the app must not
    // store it); dsh answers with the session cookie the WebView keeps.
    return Uri(scheme: 'http', host: '127.0.0.1', port: proxyPort, path: '/');
  }

  /// The tunnel re-attached after a drop — AppState usually swapped in a
  /// fresh RelayClient, while the running proxy still dials through the dead
  /// one, so every WebView request would fail silently and the page would
  /// freeze on stale content. Rebuild the proxy against the live client and
  /// reload; a same-client restore only needs the reload.
  void _onTunnelRestored() {
    final client = widget.state.client;
    if (client == null || identical(_proxyBackend, client)) {
      print('[dsh] tunnel restored, reloading webview');
      _controller?.reload();
      return;
    }
    print('[dsh] tunnel restored with a new client, rebuilding proxy');
    final proxy = WebProxy(
      client,
      remotePort: widget.state.currentConnection?.dshPort ?? 3080,
    );
    _proxyBackend = client;
    _proxy?.close();
    _proxy = proxy;
    proxy
        .start()
        .then((_) {
          if (!mounted) return;
          _controller?.loadRequest(_appUrl(proxy.port));
        })
        .catchError((Object e) {
          if (mounted) setState(() => _error = '启动本地代理失败: $e');
        });
  }

  // ---------------------------------------------------------------------------
  // Long-session rendering recovery
  // ---------------------------------------------------------------------------

  /// Periodic + on-resume renderer health probe. `1+1` costs nothing even on
  /// a busy page; a dead renderer (killed web content process, OOM) either
  /// never answers or answers with garbage. Two consecutive failures mean the
  /// page is really gone — a busy-but-alive renderer recovers within one
  /// probe, so a single timeout never reloads on its own.
  Future<void> _probeAndRecover() async {
    if (!mounted || _probing) return;
    final c = _controller;
    if (c == null || _error != null || !_pageReady) return;
    // Tunnel down: the page is stale by design; the restore path reloads it.
    if (!_lanMode && !widget.state.connected) return;
    _probing = true;
    var alive = false;
    try {
      final r = await c
          .runJavaScriptReturningResult('1+1')
          .timeout(const Duration(seconds: 6));
      alive = r.toString().contains('2');
    } catch (_) {
      alive = false; // threw or timed out: renderer not answering
    } finally {
      _probing = false;
    }
    if (alive) {
      _probeFailures = 0;
      return;
    }
    _probeFailures++;
    await _recoverFromDeadRenderer('renderer probe failed ($_probeFailures)');
  }

  /// Escalating recovery for a dead/garbled renderer: a plain reload usually
  /// brings the web process back; repeated failures mean the platform view or
  /// its surface is corrupt, so rebuild it from scratch. Bounded like the
  /// desktop shell's termination handling so a crash loop surfaces as an
  /// error instead of thrashing.
  Future<void> _recoverFromDeadRenderer(String reason) async {
    if (!mounted) return;
    if (!_lanMode && !widget.state.connected) {
      print('[dsh] $reason while the tunnel is down; waiting for restore');
      return;
    }
    if (_recoveries >= 3) {
      print('[dsh] $reason: giving up after $_recoveries recoveries');
      setState(() {
        _error = '页面进程多次崩溃，已停止自动恢复。\n请点击右下角刷新按钮，或返回后重新进入。';
      });
      return;
    }
    _recoveries++;
    print('[dsh] $reason: recovery attempt $_recoveries');
    if (_recoveries == 1) {
      await _controller?.reload();
    } else {
      await _rebuildWebView();
    }
  }

  /// Tear down the platform view (fresh [WebViewWidget] via the generation
  /// key) and load the app URL again. The proxy keeps running; the dsh
  /// session cookie outlives the view, so the reload re-authenticates
  /// silently.
  Future<void> _rebuildWebView() async {
    final proxy = _proxy;
    if (proxy == null) return;
    print(
      '[dsh] rebuilding the webview platform view (generation $_generation)',
    );
    final controller = _buildController();
    if (!mounted) return;
    setState(() {
      _generation++;
      _controller = controller;
      _pageReady = false;
      _probeFailures = 0;
      _pluginRetries = 0;
    });
    await controller.loadRequest(_appUrl(proxy.port));
  }

  /// Manual escape hatch for corruption the watchdog cannot see (a garbled
  /// compositor surface with a live renderer renders fine to JavaScript).
  /// First tap reloads in place; a second tap within a few seconds means the
  /// reload did not clear the garbage, so rebuild the platform view.
  void _manualRefresh() {
    final now = DateTime.now();
    final last = _lastManualRefresh;
    _lastManualRefresh = now;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      _rebuildWebView();
      return;
    }
    setState(() => _error = null);
    _controller?.reload();
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
    // Load through the relay tunnel (all non-LAN traffic).
    _launchWith(client);
  }

  void _launchWith(PortBackend backend) {
    final connection = widget.state.currentConnection;
    final proxy = WebProxy(backend, remotePort: connection?.dshPort ?? 3080);
    _proxy = proxy;
    _proxyBackend = backend;
    proxy
        .start()
        .then((_) {
          if (!mounted) return;
          final controller = _buildController();
          _controller = controller;
          setState(() {});
          controller.loadRequest(_appUrl(proxy.port));
        })
        .catchError((Object e) {
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
            // A finished load proves the renderer is back, so the recovery
            // ladder (and its bound) restarts from a clean slate.
            _recoveries = 0;
            _probeFailures = 0;
            _pageReady = true;
            if (_error != null && mounted) setState(() => _error = null);
            _shrinkToFitDesktop();
            _retryFailedPlugins();
            if (mounted) setState(() {});
          },
          onWebResourceError: (err) {
            print(
              '[webview] resource error: ${err.errorCode} ${err.description} url=${err.url} main=${err.isForMainFrame}',
            );
            if (err.isForMainFrame != true || !mounted) return;
            // iOS: the system killed the web content process (long-session
            // memory pressure). Not a connectivity problem — reload instead
            // of showing the offline message. (Android never reports positive
            // error codes, so matching this code is unambiguous.)
            if (err.errorCode == _webContentProcessTerminatedCode) {
              _recoverFromDeadRenderer('web content process terminated');
              return;
            }
            // The tunnel fails with 502 when the desktop host is offline —
            // show a clear message instead of a blank page. A failing direct
            // LAN load falls back to the relay tunnel first.
            if (_lanMode && !_fellBack) {
              _fellBack = true;
              _lanMode = false;
              _proxy?.close();
              _proxy = null;
              _startTunnel();
            } else {
              setState(() => _error = '无法加载电脑端页面。\n请确认电脑上的 Harness 已打开，然后重试。');
            }
          },
        ),
      );
  }

  @override
  void dispose() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    WidgetsBinding.instance.removeObserver(this);
    _probeTimer?.cancel();
    widget.state.removeListener(_onStateChanged);
    ForegroundService.stop();
    _proxy?.close();
    _lanBackend?.dispose();
    widget.state.disconnect();
    super.dispose();
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
    // With a proxy alive, rebuild the platform view — the error may be the
    // bounded-recovery give-up, where reload() alone would not clear a
    // corrupt surface. Without one (proxy/port failure) restart the bootstrap.
    if (_proxy != null) {
      _rebuildWebView();
    } else {
      _bootstrap();
    }
  }

  int _pluginRetries = 0;
  LanBackend? _lanBackend;

  /// dsh renders "Failed to load plugins" when a plugin bundle script failed
  /// to load (e.g. the desktop was mid-restart). Reload a few times so a
  /// transient 502 doesn't leave the user stuck on the error page.
  Future<void> _retryFailedPlugins() async {
    if (_pluginRetries >= 3) return;
    final c = _controller;
    if (c == null) return;
    await Future.delayed(const Duration(seconds: 4));
    try {
      final t = await c.runJavaScriptReturningResult(
        'document.body ? document.body.innerText.slice(0, 200) : ""',
      );
      if (t is String && t.contains('Failed to load plugins')) {
        _pluginRetries++;
        await c.reload();
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // Keep the WebView out of any listenable-driven rebuild: rebuilding the
    // platform view (even with the same controller) on every AppState
    // notification (session refresh etc.) can drop touch events, making the
    // page render but clicks do nothing. The reconnecting overlay is layered
    // on top via Stack instead.
    final showReconnecting =
        !_lanMode && !widget.state.connected && _controller != null;
    // The remote view replaces the home route, so an unguarded system back
    // would exit the app — route it to the connection list instead. dispose()
    // tears the tunnel/proxy/foreground-service down on navigation.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || !mounted) return;
        Navigator.of(context).pushReplacementNamed('/');
      },
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: _error != null
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
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
                      // The generation key gives the recovery path a brand
                      // new platform view instead of a possibly-corrupt one.
                      child: WebViewWidget(
                        key: ValueKey('dsh-webview-$_generation'),
                        controller: _controller!,
                      ),
                    ),
            ),
            if (showReconnecting)
              const Positioned.fill(
                child: ColoredBox(
                  color: Color(0xE6FFFFFF),
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('连接已断开，正在重新连接…'),
                      ],
                    ),
                  ),
                ),
              ),
            // Escape hatch for rendering corruption the watchdog cannot
            // detect (garbled surface with a live renderer): tap once to
            // reload, tap again within seconds to rebuild the platform view.
            if (_controller != null && _error == null && !showReconnecting)
              Positioned(
                right: 12,
                bottom: 12,
                child: SafeArea(
                  child: Opacity(
                    opacity: 0.6,
                    child: Material(
                      color: Colors.black38,
                      shape: const CircleBorder(),
                      clipBehavior: Clip.antiAlias,
                      child: InkWell(
                        onTap: _manualRefresh,
                        child: const Padding(
                          padding: EdgeInsets.all(10),
                          child: Icon(
                            Icons.refresh,
                            size: 20,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
