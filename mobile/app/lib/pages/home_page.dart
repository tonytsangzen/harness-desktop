/// Home page: saved terminal connections as cards, with a trailing "+" card
/// that opens the scan/pair flow. Tapping a card connects to that terminal
/// and opens the remote WebView. If the saved token expired, the app asks for
/// the current PIN and re-pairs before connecting.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/app_state.dart';
import '../core/relay_client.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.state});
  final AppState state;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool _connecting = false;
  String? _error;

  Future<void> _connect(SavedConnection conn) async {
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      // Direct LAN connect is preferred when the QR carried a LAN address
      // and the desktop's dsh web answers here — no relay tunnel needed.
      // Start the LAN probe and the relay connect in parallel so an
      // unreachable LAN (phone off-network) costs at most ~1s instead of
      // blocking the whole connect until the probe times out.
      final lan = conn.lan;
      if (lan != null) {
        final lanFuture = AppState.lanAvailable(lan);
        final connectFuture = widget.state.connectTo(conn);
        final lanOk = await lanFuture
            .timeout(const Duration(seconds: 1), onTimeout: () => false);
        if (lanOk) {
          // LAN won: enter the remote view with the LAN backend. Keep the
          // still-running relay connect alive (ignore its outcome) — the
          // remote view re-checks the LAN and would otherwise have nothing
          // to fall back to if that second probe fails.
          connectFuture.catchError((Object _) {});
          widget.state.currentConnection = conn;
          if (!mounted) return;
          Navigator.of(context).pushReplacementNamed('/remote');
          return;
        }
        await connectFuture;
      } else {
        await widget.state.connectTo(conn);
      }
      if (!mounted) return;
      if (widget.state.connected) {
        Navigator.of(context).pushReplacementNamed('/remote');
      } else {
        setState(() => _error = '连接失败：${widget.state.error ?? '未知错误'}');
      }
    } on RelayError catch (e) {
      if (!mounted) return;
      if (e.code == 'unauthorized') {
        // Token expired on the relay: ask for the current PIN and re-pair.
        await _repairWithPin(conn);
      } else {
        setState(() => _error = '连接失败：${e.message}');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '连接失败：$e');
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _repairWithPin(SavedConnection conn) async {
    final pinController = TextEditingController();
    final pin = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('需要重新配对'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('该终端的连接已失效。请输入电脑端「远程连接」窗口显示的 6 位 PIN：'),
            const SizedBox(height: 12),
            TextField(
              controller: pinController,
              keyboardType: TextInputType.number,
              maxLength: 6,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              autofocus: true,
              style: const TextStyle(fontSize: 24, letterSpacing: 4),
              textAlign: TextAlign.center,
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, pinController.text),
            child: const Text('重新连接'),
          ),
        ],
      ),
    );
    if (pin == null || pin.length != 6) return;
    setState(() {
      _connecting = true;
      _error = null;
    });
    try {
      await widget.state.repairConnection(conn, pin);
      if (!mounted) return;
      if (widget.state.connected) {
        Navigator.of(context).pushReplacementNamed('/remote');
      } else {
        setState(() => _error = '重新连接失败：${widget.state.error ?? '未知错误'}');
      }
    } catch (e) {
      if (!mounted) return;
      final msg = (e is RelayError && e.code == 'pair-expired')
          ? '配对失败：电脑端未在线。\n请确认电脑上的 Harness 已打开（菜单「远程连接」已启用），然后重试。'
          : '重新连接失败：$e';
      setState(() => _error = msg);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _delete(SavedConnection conn) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除连接'),
        content: Text('确定删除与 ${conn.hostId} 的连接记录？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (ok == true) {
      await widget.state.removeConnection(conn);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Harness 远程')),
      body: ListenableBuilder(
        listenable: widget.state,
        builder: (context, _) {
          final state = widget.state;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              for (final conn in state.connections) _connectionCard(context, conn),
              _plusCard(context),
            ],
          );
        },
      ),
    );
  }

  Widget _connectionCard(BuildContext context, SavedConnection conn) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: theme.colorScheme.primaryContainer,
          child: Icon(Icons.computer, color: theme.colorScheme.onPrimaryContainer),
        ),
        title: Text(conn.hostId, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(
          conn.relay,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall,
        ),
        trailing: _connecting
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
            : IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '删除',
                onPressed: () => _delete(conn),
              ),
        onTap: _connecting ? null : () => _connect(conn),
      ),
    );
  }

  Widget _plusCard(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).pushNamed('/pair'),
        child: const SizedBox(
          height: 88,
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.add, size: 40, color: Colors.grey),
                SizedBox(height: 4),
                Text('添加终端', style: TextStyle(color: Colors.grey)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
