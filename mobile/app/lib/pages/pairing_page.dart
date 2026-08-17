/// Pairing page: scan the host QR (relay:// URL) or enter relay + PIN.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/app_state.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.state});
  final AppState state;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _relay = TextEditingController(text: 'https://relay.example.com');
  final _pin = TextEditingController();
  bool _scanning = false;
  bool _fromQR = false; // relay address came from the QR code
  String _deviceId = '';
  String? _lan; // optional "ip:port" for direct LAN connect (from the QR)

  Future<void> _submit() async {
    if (_deviceId.isEmpty || _relay.text.isEmpty) {
      _snack('请先扫码获得设备码，再输入 PIN');
      return;
    }
    final pin = _pin.text.trim();
    if (!RegExp(r'^\d{6}$').hasMatch(pin)) {
      _snack('PIN 为 6 位纯数字');
      return;
    }
    try {
      await widget.state.pair(
        relayBase: _relay.text.trim(),
        deviceId: _deviceId,
        pin: pin,
        lan: _lan,
      );
      if (mounted) Navigator.of(context).pushReplacementNamed('/remote');
    } catch (e) {
      _snack('配对失败: $e');
    }
  }

  void _onDetect(BarcodeCapture capture) {
    // Already handled (or scanner hidden): ignore duplicate frames.
    if (!_scanning) return;
    final raw = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (raw == null || raw.isEmpty) return;
    if (!raw.startsWith('relay://')) {
      _snack('无法识别的二维码（应为 relay:// 开头）');
      return;
    }
    final uri = Uri.tryParse(raw);
    final device = uri?.queryParameters['device'];
    if (uri == null || device == null || device.isEmpty) {
      _snack('二维码缺少设备码，请重新生成');
      return;
    }
    // Use the scheme carried by the QR code (http for plaintext test relays);
    // fall back to loopback detection for older QR codes without one.
    final schemeParam = uri.queryParameters['scheme'];
    final host = uri.host;
    final scheme = (schemeParam == 'http' || schemeParam == 'https')
        ? schemeParam
        : (host == 'localhost' || host == '::1' || host.startsWith('127.')
            ? 'http'
            : 'https');
    setState(() {
      _deviceId = device;
      _fromQR = true;
      _scanning = false;
      _lan = uri.queryParameters['lan'];
      _relay.text = '$scheme://${uri.authority}';
    });
    _snack('已从二维码读取中继地址与设备码，请输入电脑上显示的 PIN 后确认');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('连接电脑 Agent')),
      body: _scanning
          ? MobileScanner(
              onDetect: _onDetect,
              overlayBuilder: (_, _) => const Center(
                child: Text('对准电脑上「远程连接」的二维码',
                    style: TextStyle(color: Colors.white, fontSize: 16)),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text('1. 在电脑的 DeepSeek Harness 里打开「远程连接」，显示配对二维码和 PIN',
                    style: TextStyle(fontSize: 15)),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: () => setState(() => _scanning = true),
                  icon: const Icon(Icons.qr_code_scanner),
                  label: const Text('扫描二维码'),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _relay,
                  enabled: !_fromQR, // locked once read from the QR code
                  decoration: InputDecoration(
                    labelText: _fromQR ? '中继地址（来自二维码）' : '中继地址',
                    border: const OutlineInputBorder(),
                    helperText: _fromQR ? '已从二维码提取，不可修改' : null,
                  ),
                  keyboardType: TextInputType.url,
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _pin,
                  maxLength: 6,
                  decoration: const InputDecoration(
                      labelText: 'PIN（电脑上显示的 6 位数字）',
                      border: OutlineInputBorder(),
                      counterText: ''),
                  keyboardType: TextInputType.number,
                  obscureText: true,
                ),
                const SizedBox(height: 12),
                TextField(
                  onChanged: (v) {
                    _deviceId = v.trim();
                    // Manual override: the relay is no longer QR-derived.
                    setState(() => _fromQR = false);
                  },
                  decoration: const InputDecoration(
                      labelText: '设备码（扫码后自动填入，也可手动输入）',
                      border: OutlineInputBorder()),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: widget.state.busy ? null : _submit,
                  child: widget.state.busy
                      ? const SizedBox(
                          height: 20, width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Text('连接'),
                ),
                if (widget.state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(widget.state.error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  ),
              ],
            ),
    );
  }
}
