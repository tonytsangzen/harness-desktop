/// Plain WebView for scanned http(s) links (the zcode direct-link channel):
/// opens the URL directly in the browser engine — no relay tunnel, no
/// pairing, no private protocol involved.
library;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

class LinkWebviewPage extends StatefulWidget {
  const LinkWebviewPage({super.key, required this.url});
  final String url;

  @override
  State<LinkWebviewPage> createState() => _LinkWebviewPageState();
}

class _LinkWebviewPageState extends State<LinkWebviewPage> {
  WebViewController? _controller;
  String? _error;
  bool _canGoBack = false;

  @override
  void initState() {
    super.initState();
    final uri = Uri.tryParse(widget.url);
    if (uri == null ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      _error = '链接格式无法在浏览器中打开';
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (_) {
            if (!mounted) return;
            setState(() => _error = null);
            _controller?.canGoBack().then((v) {
              if (mounted) setState(() => _canGoBack = v);
            });
          },
          onWebResourceError: (err) {
            if (err.isForMainFrame == true && mounted) {
              setState(() => _error = '无法打开该链接（${err.errorCode}）');
            }
          },
        ),
      )
      ..loadRequest(uri);
  }

  void _retry() {
    setState(() => _error = null);
    _controller?.reload();
  }

  @override
  Widget build(BuildContext context) {
    // No app bar: content fills the screen. A floating back button at the
    // top-left steps back through the WebView history first, and leaves the
    // page once there is no in-web history left.
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(
            child: _controller == null
                ? Center(child: Text(_error ?? ''))
                : WebViewWidget(controller: _controller!),
          ),
          Positioned(
            left: 12,
            top: MediaQuery.paddingOf(context).top + 8,
            child: _BackButton(
              visible: _canGoBack,
              onTap: () {
                final controller = _controller;
                if (controller != null && _canGoBack) {
                  controller.goBack();
                } else if (mounted) {
                  Navigator.of(context).maybePop();
                }
              },
            ),
          ),
          if (_error != null && _controller != null)
            Positioned.fill(
              child: ColoredBox(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, textAlign: TextAlign.center),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _retry,
                        icon: const Icon(Icons.refresh),
                        label: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Translucent circular back affordance that only shows while the WebView
/// has in-page history to go back to.
class _BackButton extends StatelessWidget {
  const _BackButton({required this.visible, required this.onTap});
  final bool visible;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    return Material(
      color: Colors.black.withValues(alpha: 0.35),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: const Padding(
          padding: EdgeInsets.all(10),
          child: Icon(Icons.arrow_back, color: Colors.white, size: 22),
        ),
      ),
    );
  }
}
