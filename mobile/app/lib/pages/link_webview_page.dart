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

  /// System back: step back through the WebView history first; only when
  /// the in-web history is exhausted does the page itself pop back to the
  /// saved-link list.
  Future<void> _onSystemBack(bool didPop, Object? result) async {
    if (didPop) return;
    final controller = _controller;
    if (controller != null && _canGoBack) {
      await controller.goBack();
      if (!mounted) return;
      final still = await controller.canGoBack();
      if (mounted) setState(() => _canGoBack = still);
    } else if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    // No app bar, no overlay buttons: content fills the screen and the
    // system back gesture navigates the WebView history first.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: _onSystemBack,
      child: Scaffold(
        body: Stack(
          children: [
            Positioned.fill(
              child: _controller == null
                  ? Center(child: Text(_error ?? ''))
                  : WebViewWidget(controller: _controller!),
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
      ),
    );
  }
}
