# 手机 App 远程 Agent 监控架构

手机 App 展示的是电脑上的 dsh Web UI。App 不复制 dsh 的会话、事件、审批或 RPC 协议，而是把 WebView 的 TCP 连接通过透明端口流送到电脑端 dsh。

## 总体架构

```text
Flutter WebView
  -> App 127.0.0.1 TCP proxy
  -> Device WSS
  -> Go relay
  -> Host WSS
  -> Node desktop bridge
  -> 127.0.0.1:<dsh-port>
  -> dsh Web UI/API/WebSocket
```

### Relay

relay 只提供：

- Host 注册和 hostToken；
- Device 使用设备码/PIN 配对和 sessionToken；
- token 刷新、吊销、在线状态和心跳；
- `stream-open`、`stream-data`、`stream-close` 的双向路由。

relay 不读取 TCP payload，不识别 HTTP、WebSocket、SSE、RPC、JSON、cookie 或会话列表，也不生成业务错误响应。

### Desktop bridge

bridge 出站连接 relay。收到 `stream-open` 后连接本机 dsh TCP 端口，将 socket 两端字节互相复制；收到 close 或本地 socket 关闭时结束 stream。bridge 同时可在 LAN 上暴露同一个透明 TCP 端口。

### Flutter App

App 完成配对并建立 Device WSS。`WebProxy` 接受 WebView 的本地 TCP 连接，每条连接对应一个远程 port stream。它只为本地代理兼容性修改初始 HTTP 头中的 `Host` 和 `Origin`，其他数据原样转发。

## 关键设计结果

1. WebView 直接运行 dsh 原有页面，因此会话列表、实时事件、审批、插件资源和 WebSocket 行为由 dsh 自己处理。
2. relay 与 dsh 本体完全解耦；dsh 协议升级不需要修改 relay。
3. LAN 和 relay 使用同一 `PortBackend` 抽象，故障切换只替换传输端，不改变 WebView。
4. 不保留旧的 RPC/SSE/HTTP frame 兼容层。任何协议升级由 dsh 自身和 WebView 共同完成。

## 生命周期与故障处理

- 配对成功后 App 保存 session/refresh token；Device WSS 断开时指数退避重连。
- relay 或 bridge 关闭 stream 时，本地 WebView socket 结束当前请求；relay 恢复后 App reload 页面。
- dsh 未监听、端口错误或 bridge 无法连接时，bridge 关闭 stream，App 显示连接失败。
- bridge 的 hostToken 只用于 relay Host 身份恢复；dsh 的认证配置不放进 bridge 或 relay。

## 验收范围

- relay/bridge E2E：注册、配对、任意二进制数据双向转发、stream 隔离和关闭；
- Flutter 单测：Device stream 帧、二进制数据、ping/pong；
- Flutter 集成测试：本地 TCP 代理、Host/Origin 修改、响应字节透明和多连接隔离；
- 真机：WebView 首屏、会话列表、资源加载、WebSocket 实时更新和页面交互。
