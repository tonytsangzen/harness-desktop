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
            if (mounted) setState(() => _error = null);
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
    // No top bar: content fills the screen; system back/gesture navigates.
    return Scaffold(
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
    );
  }
}
