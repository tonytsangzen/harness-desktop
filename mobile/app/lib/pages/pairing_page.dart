/// Pairing page: scan the host QR (relay:// URL) or enter relay + PIN.
library;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/app_state.dart';
import '../core/pairing_link.dart';

class PairingPage extends StatefulWidget {
  const PairingPage({super.key, required this.state});
  final AppState state;

  @override
  State<PairingPage> createState() => _PairingPageState();
}

class _PairingPageState extends State<PairingPage> {
  final _relay = TextEditingController(text: 'https://relay.deepvisus.top');
  final _pin = TextEditingController();
  bool _scanning = false;
  bool _fromQR = false; // relay address came from the QR code
  String _deviceId = '';
  String? _lan; // optional "ip:port" for direct LAN connect (from the QR)
  String? _e2eSecret; // tunnel E2E secret (shared via QR, relay-blind)
  int _dshPort = 3080;
  String? _qrPin; // PIN carried by the QR: pairing proceeds without typing

  Future<void> _submit() async {
    if (_deviceId.isEmpty || _relay.text.isEmpty) {
      _snack('请先扫码获得设备 ID，再输入 PIN');
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
        e2eSecret: _e2eSecret,
        dshPort: _dshPort,
      );
      if (mounted) Navigator.of(context).pushReplacementNamed('/remote');
    } catch (e) {
      _snack('配对失败: $e');
    }
  }

  Future<void> _onDetect(BarcodeCapture capture) async {
    // Already handled (or scanner hidden): ignore duplicate frames.
    if (!_scanning) return;
    final raw = capture.barcodes.firstOrNull?.rawValue?.trim();
    if (raw == null || raw.isEmpty) return;
    // Two channels, distinguished semantically:
    // - relay:// → this app's pairing QR: parsed and validated, auto-pairs;
    // - anything else with a URI scheme → the zcode direct-link channel:
    //   NO validation, the link is saved verbatim (with any device/pin/e2e
    //   params carried along) and the page returns to the saved list.
    if (!raw.startsWith('relay://')) {
      final link = parseDirectLink(raw);
      if (link == null) {
        _snack('无法识别的内容');
        return;
      }
      await widget.state.addLinkConnection(
        SavedConnection(
          relay: link.origin,
          hostId: link.device ?? '',
          sessionToken: '',
          refreshToken: '',
          pairedAt: DateTime.now().millisecondsSinceEpoch,
          e2eSecret: link.e2eSecret,
          pin: link.pin ?? '',
          link: link.raw,
          dshPort: link.dshPort,
        ),
      );
      if (!mounted) return;
      _snack('已保存链接');
      Navigator.of(context).pop();
      return;
    }
    final data = parsePairingContent(raw);
    if (data == null) {
      _snack('无法识别的二维码（应为 relay:// 或 http/https 链接）');
      return;
    }
    setState(() {
      _deviceId = data.deviceId ?? _deviceId;
      _fromQR = true;
      _scanning = false;
      _lan = data.lan;
      _e2eSecret = data.e2eSecret;
      if (data.pin != null) {
        _qrPin = data.pin;
        _pin.text = data.pin!;
      }
      _dshPort = data.dshPort;
      _relay.text = data.relayBase;
    });
    if (_qrPin != null && data.deviceId != null) {
      // The QR carries everything: pair immediately, no PIN prompt.
      await _submit();
      return;
    }
    _snack(
      data.deviceId == null
          ? '已读取中继地址，请补充设备 ID 后连接'
          : '已从二维码读取中继地址与设备 ID，请输入电脑上显示的 PIN 后确认',
    );
  }

  // mobile_scanner re-detects the same frame continuously, and the toast
  // outlives the page — without dedupe one bad scan toasts for seconds and
  // again after navigating back.
  DateTime? _lastSnackAt;
  String? _lastSnackMsg;

  void _snack(String msg) {
    if (!mounted) return;
    final now = DateTime.now();
    if (msg == _lastSnackMsg &&
        _lastSnackAt != null &&
        now.difference(_lastSnackAt!) < const Duration(seconds: 3)) {
      return;
    }
    _lastSnackAt = now;
    _lastSnackMsg = msg;
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
                child: Text(
                  '对准电脑上「远程连接」的二维码',
                  style: TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  '1. 在电脑的 DeepSeek Harness 里打开「远程连接」，显示配对二维码和 PIN',
                  style: TextStyle(fontSize: 15),
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
                    counterText: '',
                  ),
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
                    labelText: '设备 ID（扫码后自动填入，也可手动输入）',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: () => setState(() => _scanning = true),
                        icon: const Icon(Icons.qr_code_scanner),
                        label: const Text('扫描二维码'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton(
                        onPressed: widget.state.busy ? null : _submit,
                        child: widget.state.busy
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Text('连接'),
                      ),
                    ),
                  ],
                ),
                if (widget.state.error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Text(
                      widget.state.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }
}
