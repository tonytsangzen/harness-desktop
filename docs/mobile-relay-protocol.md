# Mobile Relay 协议 v2：透明 TCP 端口流

本文是远程连接三端（relay、desktop bridge、Flutter App）的唯一线路规范。
旧的 `rpc`、`sse-*`、`http`、`respond`、`signal` 帧不再属于协议，服务端不兼容、不解析、也不生成这些帧。

## 1. 架构边界

```text
WebView
  -> 127.0.0.1:<app-proxy-port>       Flutter 本地 TCP 代理
  -> WSS stream-open/data/close        Device
  -> WSS stream-open/data/close        Relay（只按身份路由）
  -> WSS stream-open/data/close        Desktop bridge
  -> 127.0.0.1:<dsh-port>             dsh 原生 TCP 服务
```

组件职责固定如下：

| 组件 | 负责 | 不负责 |
| --- | --- | --- |
| Relay | 注册、配对、鉴权、心跳、stream 绑定和双向转发 | 不读取 `data`，不理解 HTTP/WebSocket/RPC/SSE/JSON |
| Desktop bridge | 将每个 stream 接到本机 dsh TCP 端口；暴露同一端口的 LAN TCP 代理 | 不包装、改写或解析 dsh 协议 |
| Flutter App | 建立 Device WSS、本地 TCP 代理、WebView 加载 | 不在应用层实现 dsh API 或 SSE 适配 |
| dsh | 提供原本的本地 TCP/HTTP/WebSocket 服务 | 不依赖 relay 的协议实现 |

`data` 是 base64 编码的 TCP 字节块。base64 只是 JSON 传输层编码，不代表 relay 可以查看其内容；只有 bridge 和 WebView 对端处理这些字节。

## 2. 端点和控制面

| 端点 | 用途 |
| --- | --- |
| `wss://<relay>/relay/v1/host` | Desktop bridge 出站连接 |
| `wss://<relay>/relay/v1/device` | App 出站连接 |
| `https://<relay>/relay/v1/pair` | App 使用设备码和 PIN 配对 |
| `https://<relay>/relay/v1/pair/refresh` | 使用 refresh token 换 session token |
| `https://<relay>/relay/v1/revoke` | 吊销 App 会话 |
| `https://<relay>/relay/v1/host/devices` | Host 查询已配对设备在线状态 |

### 2.1 Host 注册

首次连接后 bridge 发送：

```json
{
  "v": 1,
  "type": "control",
  "kind": "register",
  "body": {
    "hostId": "0123456789012",
    "hostName": "Tony-MBP",
    "dshVersion": "0.1.0",
    "pin": "814304",
    "token": "ht_previous"
  }
}
```

relay 返回：

```json
{
  "v": 1,
  "type": "control",
  "kind": "registered",
  "body": {
    "hostId": "0123456789012",
    "hostToken": "ht_new",
    "pin": "814304",
    "pinExpiresAt": 0
  }
}
```

`hostId` 由桌面壳生成并保持稳定。首次注册可不带 token；已有 Host 必须带有效 `token`，否则返回 `register-denied` / `host-conflict`。bridge 保存 `hostToken` 后，重连时通过 `Authorization: Bearer <hostToken>` 直接恢复；relay 丢失内存状态时会要求重新发送 register。

### 2.2 Device 配对

```http
POST /relay/v1/pair
Content-Type: application/json

{"deviceId":"0123456789012","pin":"814304"}
```

成功响应包含 `hostId`、`deviceId`、`sessionToken` 和 `refreshToken`。App 之后连接 Device WSS 时携带：

```http
Authorization: Bearer <sessionToken>
```

配对失败统一返回 `pair-invalid`（限速除外），避免通过错误码探测 Host 或 PIN 状态。会话过期使用 `/pair/refresh` 换新 token。

## 3. 透明 stream 帧

WSS 使用 JSON 文本消息。控制帧只有心跳和注册；数据帧只有以下三种：

### `stream-open`

Device -> Relay -> Host。一个 WebView TCP 连接只发送一次：

```json
{"v":1,"type":"stream-open","streamId":"stream_abc","port":3080}
```

Relay 验证 `streamId` 非空、`port` 在 `1..65535`，随后绑定 `hostId/streamId -> deviceId` 并转发原帧。bridge 只允许配置的 dsh port（默认 `3080`），不匹配则回 `stream-close` / `port-not-exposed`。

### `stream-data`

任一端 -> Relay -> 对端：

```json
{"v":1,"type":"stream-data","streamId":"stream_abc","data":"AAECf4D+/w=="}
```

Relay 只使用 `hostId + streamId` 查找目标设备，原样转发 `data`。它不得 base64 解码、记录、截断或根据内容改变路由。双方可按 TCP `data` 事件大小自行分块；单个 WSS 消息受 relay 8 MiB 读取上限约束。

### `stream-close`

任一端 -> 对端：

```json
{"v":1,"type":"stream-close","streamId":"stream_abc","reason":"eof"}
```

Relay 转发后删除 stream 绑定。`reason` 仅用于诊断，不是 dsh 业务错误码。

### `ping` / `pong`

relay 每 30 秒向两端发送文本 `{"v":1,"type":"ping"}`，两端回复 `pong`。任意入站帧（包括文本 pong）刷新 90 秒读超时；超过该时间关闭连接并由客户端退避重连。

未知 `type` 必须忽略，不得当作旧协议处理，也不得生成 RPC/HTTP 形式的错误响应。

## 4. 本地代理行为

Flutter `WebProxy` 绑定 `127.0.0.1` 的本地临时端口。每个 accepted TCP socket 建立一个 `PortBackend.connectPort(3080)`，并在两侧持续复制字节直到任一侧关闭。

为了让 dsh 接受来自本地代理的请求，代理只对首个 HTTP 请求头做两项兼容处理：

1. 将 `Host` 改为 `127.0.0.1:3080`；
2. 删除 `Origin`。

请求 body、HTTP 响应、WebSocket upgrade、WebSocket 帧和所有后续字节均透明复制。代理不缓存、压缩解码、ETag 重验证或注入 HTML。

新版 dsh 的根页面需要先用启动时生成的 `token` 换取浏览器 cookie。桌面端把
`dshToken` 和实际 `dshPort` 放入配对二维码；App 配对后首次加载本地代理的
`/?token=<dshToken>`，dsh 返回的 `303`、`Set-Cookie` 和后续重定向仍按 HTTP/TCP
原样通过代理。该 token 只属于 dsh，不是 relay 的 `sessionToken`；relay 不读取或
验证它。

LAN 模式由 bridge 暴露 `0.0.0.0:13080`，是同一个 dsh TCP 端口的透明 TCP 转发；App 仍通过本地 `WebProxy` 访问它，因此 LAN 和 relay 的 WebView 行为一致。

## 5. 连接生命周期

```text
bridge -> host WSS -> register -> registered
App    -> pair HTTP -> sessionToken
App    -> device WSS -> stream-open -> relay -> bridge
WebView <-> App local TCP proxy <-> opaque stream <-> bridge <-> dsh TCP
```

- relay 重启会丢失内存中的配对和 token；需要重新配对。
- bridge 的 hostToken 重连不会劫持仍活跃的同 Host 连接；沉默超过 `staleHostAfter` 的旧连接可被同 token 接管。
- Device WSS 断开时，App 关闭本地 stream 并按指数退避重连；恢复后 WebView reload。
- dsh 认证和访问控制由 dsh 或其独立端口层负责，relay/bridge 不实现 dsh cookie、HTTP 登录或业务认证。

## 6. 安全与部署约束

- 生产环境必须使用 TLS/WSS 和正式证书。
- relay 校验 `hostToken`、`sessionToken`，配对接口限速；token 不写入业务日志。
- relay 日志只记录连接、注册、配对、关闭和 stream 元数据，不记录 `data`。
- dsh 默认只监听 `127.0.0.1:<port>`；LAN 暴露端口必须由用户主动开启并由网络环境保护。
- relay 单个连接设置发送队列和写超时；慢消费者关闭整条隧道，避免静默丢字节。

## 7. 验证命令

```bash
go test ./...
node --check mobile/relay/e2e.mjs
node --check mobile/bridge/bridge.mjs
node --check mobile/bridge/e2e.mjs
flutter test
```

透明链路验收必须覆盖：任意二进制字节双向不变、多个 stream 不串流、WebView 请求头改写、WebSocket upgrade 和 dsh 返回数据原样到达。
