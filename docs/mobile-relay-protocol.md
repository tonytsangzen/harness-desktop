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

桌面 PIN 是稳定的（首次生成后持久化），因此配对二维码直接携带 `pin=`：手机扫码即完成配对，无需手动输入；App 把该 PIN 随连接持久化，session 过期时用它静默重新配对（PIN 在桌面端被修改过才回退到手动输入）。

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

### `stream-batch`

任一端 -> 对端：把多个流的 payload 聚合进一帧，减少小包 WSS 消息数：

```json
{"v":1,"type":"stream-batch","items":[{"id":"stream_abc","data":"AAECf4D+/w=="},{"id":"stream_def","data":"…"}]}
```

Relay 逐项按独立 `stream-data` 路由（`1..128` 项，空 `id` 跳过）。仅聚合数据；`stream-close` 仍单独成帧，且发送方必须先冲刷聚合队列再发 close。

### `stream-close`

任一端 -> 对端：

```json
{"v":1,"type":"stream-close","streamId":"stream_abc","reason":"eof"}
```

Relay 转发后删除 stream 绑定。`reason` 仅用于诊断，不是 dsh 业务错误码。

### E2E 记录层（端到端加密 + 压缩 + 聚合）

`data`/`items[].d` 的内容在两端（bridge 与 App）之间可选地升级为 **E2E 记录**，中继仍只做不透明转发：

```
'E2E1' | flags | nonce(12) | AES-256-GCM ciphertext(+16B tag)
flags:  bit0 = payload 为 deflate-raw 压缩，bit1 = 发送方支持 stream-batch
nonce:  direction(4 BE: 1=bridge→device, 2=device→bridge) || counter(8 BE)，按方向递增
AAD:    magic | flags
```

- **密钥**：`HKDF-SHA256(ikm = e2eSecret, salt = hostId, info = "dsh-e2e-v1", L = 32)`。`e2eSecret` 是桌面壳生成并持久化的 32 字节随机数，通过 `--e2e-secret` 传给 bridge、经配对二维码的 `e2e=` 参数离线交给 App——中继永远看不到
- **协商**：持有密钥的一端在每个 stream 的**第一个 payload** 注入 HELLO 记录（空 payload，flags 含 bit1）。对端解出 HELLO 即确认并回 HELLO，随后双向密封；第一个 payload 非 `E2E1` 开头则该流保持明文（legacy 对端零破坏）；解密失败（密钥不符/被篡改）直接关闭该流，绝不向 dsh/WebView 透传垃圾
- **压缩**：payload ≥ 64B 时先 deflate-raw，更小才置 bit0
- **聚合**：小 TCP 读写按 ~4ms 窗口合并为一条记录；多条流的记录再按 ~3ms 聚合为 `stream-batch`。单向未确认前不启用聚合

安全边界：中继不可见 payload 内容，但可见流元数据（streamId、字节数、条目数）；主动丢弃 HELLO 可降级为明文（防御目标是被动窥视与误配日志，不假设中继恶意）。

### `ping` / `pong`

relay 每 30 秒向两端发送文本 `{"v":1,"type":"ping"}`，两端回复 `pong`。任意入站帧（包括文本 pong）刷新 90 秒读超时；超过该时间关闭连接并由客户端退避重连。

未知 `type` 必须忽略，不得当作旧协议处理，也不得生成 RPC/HTTP 形式的错误响应。

## 4. 本地代理行为

Flutter `WebProxy` 绑定 `127.0.0.1` 的本地端口。每个 accepted TCP socket 建立一个 `PortBackend.connectPort(3080)`，并在两侧持续复制字节直到任一侧关闭。

绑定端口优先使用远端 dsh 端口（默认 `3080`，被占用时依次回退 `38080`、临时端口）。这样 WebView 的 origin 与桌面端 dsh 完全一致（`http://127.0.0.1:3080/`）。

代理**不做任何 HTTP 头改写**，请求 body、HTTP 响应、WebSocket upgrade 和所有字节均透明复制。历史上代理曾把首个请求的 `Host` 改写为 `127.0.0.1:3080` 并删除 `Origin`，但 HTTP keep-alive 复用连接上的后续请求无法逐一改写；而 dsh 的浏览器会话 cookie 与请求的 Host authority 绑定（cookie 名与签名 payload 均含 `sha256(Host)`），每次请求都会重新校验——authority 不一致的请求会得到 `401 dsh web authentication required`，这正是远程端报错的根源。origin 一致后，每个请求的 `Host`/`Origin`/cookie authority 天然一致，且满足 dsh 的 loopback + same-origin 请求围栏。代理不缓存、压缩解码、ETag 重验证或注入 HTML。

新版 dsh 的根页面需要先用启动时生成的 `token` 换取浏览器 cookie，该 token 属进程级（`dsh web` 每次重启都轮换），因此**二维码与 App 不携带、不存储它**：桌面壳把当前 token 传给 bridge（`--dsh-token`，并持久化最近一次取到的值，复用已运行的 dsh 实例时也有值可用），bridge 对每条流的**第一个 `GET /` 请求**自动补 `?token=<token>`——dsh 回 `303 + Set-Cookie`，WebView 存下会话 cookie，之后所有请求靠 cookie 鉴权。dsh 的 cookie 签名密钥持久化在 dsh profile 中，所以 dsh 重启后旧 cookie 仍有效（注入的过期 token 会被 `isAuthenticated` 分支无害地重定向），手机无需重新配对。配对二维码只携带 `e2eSecret` 和实际 `dshPort`。

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
