# Mobile Relay 协议规格 v1（可实现）

> 三端（云中继 / 主机桥接层 / 手机 App）共享的线路协议。
> 传输一律 **WSS**（TLS + 正式证书）；数据一律 **JSON**（UTF-8）。
> 本文档是实现的唯一事实来源；与 `docs/mobile-agent-monitor.md` 架构文档配套。

---

## 1. 端点与版本

| 端点 | 用途 | 连接方 |
| --- | --- | --- |
| `wss://<relay>/relay/v1/host` | Host 隧道 + 控制面 | 主机桥接层（出站长连接） |
| `wss://<relay>/relay/v1/device` | Device 隧道 | 手机 App（出站长连接） |
| `https://<relay>/relay/v1/pair` | 配对（HTTP POST） | 手机 App（一次性） |
| `https://<relay>/relay/v1/revoke` | 吊销（HTTP POST） | 手机 App / Host（可选） |

- 版本协商：路径内 `v1`；协议演进新增端点路径段，不破坏旧版。
- 所有请求/响应头：`Content-Type: application/json`；WSS 帧为单个 JSON 文本帧。

---

## 2. 控制面

### 2.1 Host 注册（WSS 内第一条控制帧）

Host 连上 `/relay/v1/host` 后，第一条消息必须是注册：

```json
{ "v": 1, "type": "control", "kind": "register",
  "body": { "hostId": "0123456789012", "hostName": "Tony-MBP", "dshVersion": "0.1.0-rc.6",
            "pin": "814304", "token": "ht_…" } }
```

- `hostId`：**壳生成的 13 位纯数字设备 ID**（设备信息派生，见 §2.3）。首次注册即携带，中继将其作为 Host 标识（未知 ID 直接建号，已知 ID 复用并刷新 token/PIN）。
- `pin`（可选）：**固定配对 PIN**。壳在首次启动随机生成并持久化（UserDefaults），每次注册都携带；中继将其作为该 Host 的长期 PIN（`pinExpiresAt: 0`，无过期、可重复使用，配对失败 5 次锁 15 分钟）。不带 `pin` 且 Host 已有固定 PIN 时保持原值；从未设置过则回退短时效 PIN。可在「设置…」中修改。**弱 PIN 会被拒绝**（`000000`、`123456`、连续/相同数字等，见 §5 `weak-pin`）。
- `token`（可选）：**上次注册拿到的 hostToken**（壳持久化于 UserDefaults）。**安全约束**：`hostId` 已存在于中继时，注册必须携带有效 `token`，否则中继拒绝（`host-conflict`）——防止任何知道 hostId 的人匿名重注册劫持 Host（踢掉真 bridge、截获设备流量）。全新 hostId（首次注册/中继重启后）无此要求。

中继响应：

```json
{ "v": 1, "type": "control", "kind": "registered",
  "body": { "hostId": "0123456789012", "hostToken": "ht_…",
             "pin": "814304", "pinExpiresAt": 1755300000000 } }
```

拒绝响应（同步写入后关闭连接）：

```json
{ "v": 1, "type": "control", "kind": "register-denied", "code": "host-conflict" }
```

- `hostToken`：Host 断线重连时作为 WSS `Authorization: Bearer` 头携带（服务端校验后直接恢复在线，不再二次注册）；壳将其持久化（`mobileHostToken`），bridge 重启时经 `--host-token` 传回。
- `pin`：固定 PIN（壳提供，`pinExpiresAt=0`）或短时效单次 PIN（默认 10 分钟）。**二维码由壳生成**（内容为 `relay://<relay>/pair?device=<hostId>`，不含 PIN——PIN 需在电脑端查看）。
- 重复注册（已在线 hostId 再连）：旧连接被踢（409 `host-replaced`），新连接接管（需有效 token）。
- Host 端到端（隧道正常时）可随时用控制帧 `{kind:"unregister"}` 主动下线。

### 2.2 Device 配对（HTTP）

```
POST /relay/v1/pair
{ "deviceId": "0123456789012", "pin": "814304" }
```

- `deviceId` 来自电脑端二维码（`device=` 参数）或手动输入的设备码；`pin` 在电脑端显示。

成功：

```json
{ "hostId": "0123456789012", "deviceId": "d_5a2c…",
  "sessionToken": "st_…", "sessionExpiresAt": 1755386400000,
  "refreshToken": "rt_…" }
```

错误（HTTP 状态 + 错误码，见 §5）。**错误码有意统一为 `pair-invalid`**（除限速 `rate-limited` 外），使 pair 端点无法被用来探测 hostId 是否存在、PIN 是否过期或已被消费：

| 情形 | 状态 | code |
| --- | --- | --- |
| deviceId 不存在/未注册/PIN 过期 | 409 | `pair-expired` |
| PIN 错误 | 409 | `pair-invalid`（同一 host 累计 5 次失败 → 锁定 15 分钟，返回 `pair-locked`） |
| 已被使用 | 409 | `pair-used` |
| Host 已离线 | 409 | `host-offline`（配对保留，Host 上线后 App 可重试连接） |

- `sessionToken`：有效期默认 24h；App 持 `refreshToken` 调用 `POST /relay/v1/pair/refresh`（`{refreshToken}`）换新会话。
- 一个 Host 默认最多绑定 8 个 Device（超限返回 `device-limit`）。

### 2.3 设备 ID 与二维码（壳生成）

- **设备 ID（hostId）**：**13 位纯数字**，由设备信息派生（`SHA-256(机器名 | IOPlatformUUID)` 取前 8 字节 mod 10^13），**跨启动稳定、无需持久化**，作为中继 Host 标识。ID 本身可从公开机器信息推导，防劫持由注册 token 约束承担（见上节 `token` / `host-conflict`），不依赖 ID 熵。
- **二维码内容**（壳端生成，`relay://<relay-host>/pair?device=<hostId>`）：仅含中继地址与设备 ID，**不含 PIN**。手机扫码得到中继地址 + 设备码，PIN 需在电脑端查看输入。
- 点击「远程连接…」流程：生成设备 ID + 二维码 → spawn bridge（`--device-id <ID>` 连接中继注册）→ **注册成功**（收到 registered）才弹出配对窗口（二维码 + PIN + 设备码）；12 秒内未注册成功 → 提示「中继服务器不可用」并停止 bridge。

### 2.4 吊销（HTTP）

```
POST /relay/v1/revoke   Authorization: Bearer <sessionToken | hostToken>
{ "deviceId": "d_…" }   // 可选；缺省 = 吊销自己
```

返回 `{ "revoked": true }`。被吊销的会话立即失效（隧道关闭）。

### 2.5 Host 查询设备（HTTP）

壳侧用 hostToken 查询中继，确认 App 是否已配对/在线（而非猜测）：

```
GET /relay/v1/host/devices   Authorization: Bearer <hostToken>
```

返回：

```json
{
  "hostId": "9900112233445",
  "devices": [
    { "deviceId": "d_…", "online": true,  "pairedAt": 1786888413542 },
    { "deviceId": "d_…", "online": false, "pairedAt": 1786888366150 }
  ]
}
```

- `online` = 该 device 当前是否有活跃隧道连接（中继实时判定）。
- 配对窗口据此轮询显示「远程 App 已连接」状态；bridge `registered` 事件会附带 `hostToken` 供壳调用本端点。

---

## 3. 数据面隧道帧

Host 与 Device 的 WSS 均为**双向 JSON 文本帧**：

```json
{
  "v": 1,
  "type": "rpc" | "rpc-reply" | "sse-open" | "sse-frame" | "sse-close" | "respond" | "http" | "http-reply" | "ping" | "pong",
  "channel": "ch_<uuid>",
  "rpcId": "rpc_<uuid>",
  "id": "http_<uuid>",
  "method": "GET",
  "status": 200,
  "path": "/api/session.list",
  "body": { }
}
```

字段规则：

| 字段 | 必填 | 说明 |
| --- | --- | --- |
| `v` | 是 | 恒为 1 |
| `type` | 是 | 帧类型（见下） |
| `channel` | rpc/rpc-reply/sse-*/http 必填 | 隧道内复用通道标识；RPC 一对请求/应答共用一个 channel |
| `rpcId` | rpc/rpc-reply 必填 | 关联请求与应答；应答帧携带与请求相同的 rpcId |
| `id` | http/http-reply 必填 | 关联 HTTP 请求与应答（对应 RPC 的 rpcId） |
| `method` | http 必填 | HTTP 方法（GET/POST/…） |
| `status` | http-reply 必填 | 上游 HTTP 状态码 |
| `path` | rpc/sse-open/respond/http 必填 | dsh web 的路径（`/api/session.list`、`/api/events.mux`、`/assets/…`…） |
| `body` | 各类型按需 | 载荷（下详） |

### 3.1 帧类型语义

**`rpc`**（Device→Relay→Host，请求）
- `body` = **业务 payload**（dsh RPC 方法的 payload，如 `session.list` 的 `{}`）。
- bridge 负责包装成 dsh 的 `client-request` 信封（`{type:"client-request", rpcId(新生成), method, payload}`）POST 给 dsh web。

**`rpc-reply`**（Host→Relay→Device）
- `body` = dsh 的 `server-response.result`（`{ok:true, value}` 或 `{ok:false, error}`）**原样透传**。
- `rpcId` 回显 device 请求帧的 rpcId。
- 传输层错误（Host 离线、dsh 无响应）用 `body = {ok:false, error:{code, message, transport:true}}`。

**`sse-open`**（Device→Relay→Host）
- 请求打开一条流：`path` = `/api/events.mux` 或 `/api/events.host`。
- `body.raw=true`（WebView 代理模式）：bridge 用 **WebSocket** 连接 dsh 的 events 端点（真实 dsh 的 mux/host 是 downlink-only WebSocket，非 SSE），收到每个文本帧**原样**以 `sse-frame {body:{data:<原始JSON>}}` 转发（`body` 无 `data` 键时才是窄形翻译帧）。
- 默认（原生模式）：`body` = 打开参数（mux 的 `{since?}`），bridge 对 dsh 打开流后回窄形 `sse-frame`。

**`sse-frame`**（Host→Relay→Device）
- 窄形：`body` = dsh `server-request` 的窄形 `{rpcId, method, payload}`（payload 为 MuxFrame/HostFrame）。
- raw：`body` = `{data: <dsh WebSocket 文本帧原文>}`（WebView 原样回放）。
- **`rpcId` 是关键**：应答型帧（`approval/requested`、`question/requested`）后续 `respond` 必须回显它。
- 顺序保证：同一 channel 帧严格按序转发。

**`sse-close`**（任一方）
- `body` = `{ "reason": "eof" | "error" | "cancelled" }`。bridge 侧流结束/出错时发；Device 侧取消订阅时发（bridge 关闭 dsh 流）。

**`respond`**（Device→Relay→Host）
- 审批/提问应答：`path` = `/api/respond`，`body` = client-response 的 `result`（`{ok:true, value:{approvalId, outcome,…}}`），`rpcId` = 对应 SSE 帧的 rpcId。
- bridge 包装成 dsh `client-response` 信封 POST `/api/respond`，并把 dsh 回执（`{accepted:true|false, reason?}`）作为 `rpc-reply` 返回。

**`http`**（Device→Relay→Host，WebView 代理）
- 通用 HTTP 代理帧：`id` = 请求关联 ID，`method` = HTTP 方法，`path` = 完整路径（含 query，如 `/plugins/@deepseek-ai/dsh-client-connection/client.js?rev=…`）。
- `body.headers` = 请求头（Host 头不转发）；`body.body` = 请求体 **base64**（二进制安全）。

**`http-reply`**（Host→Relay→Device）
- `id` 回显请求；`status` = 上游状态码；`body.headers` = 响应头（content-type、location）；`body.body` = 响应体 **base64**。
- **大响应分片**：超过 ~192 KiB 的响应由 bridge 拆成多条 `http-reply` 帧发送，`body.part = {index, total}`（index 从 0 起）；`headers` 只随 part 0 携带，各帧 `status` 相同。Device 按 id 重组，收齐 `total` 片后合并 body。分片发送配合 Device 侧的**空闲超时**（见 §4）：只要分片持续到达，传输就不会被总时长上限掐断。
- **中途失败**：`body.abort = true`（status=502），Device 立即以 502 结束该请求。
- 代理失败（小响应）：单帧 `status=502`，body 为错误文本。

**`ping` / `pong`**
- 双方每 30s 发 `ping`（`{}` 即可），对端回 `pong`；90s 无任何帧视为死链，中继/客户端主动断开并走重连。

### 3.2 多路复用与背压

- 单条 WSS 上多 channel 并行（每会话一个 mux channel、每 RPC 一个 channel）。
- 中继每条隧道一个发送队列（1024 帧）。**队列打满（慢消费者）或写超时（10s）时关闭该隧道**——静默丢帧会让对端永远等不到应答，关隧道触发两端干净重连反而恢复更快。
- 大帧：大响应体由 bridge 以 `body.part = {index, total}` 分片发送（`http-reply` 分片见 §3.1）；单帧上限由中继 `SetReadLimit`（8 MiB）约束。
- 中继 ping 每 30s；90s 无任何入站帧判定死链（pong / 任意帧均会刷新）。

### 3.3 事件子集（App 消费清单）

App 只需识别以下 `session/event` 的 `type`（其余原样忽略、不断流）：

```
step/start, step/end
assistant/chunk, assistant/message
tool/call, tool/result
approval/asked, approval/decided
command/run, command/done
session/title
```
以及 mux 帧：`session/subscribed`、`session/queue`、`session/jobs`；
host 帧：`session/create`、`session/destroy`、`host/status`（running 翻转/离线）。

---

## 4. 连接生命周期

```
Host:
  connect(no auth) → register → [registered: hostToken] → 隧道就绪
  断线 → 指数退避(1s,2s,4s…max 10s) 重连，带 Authorization: Bearer hostToken
  重连成功 → 中继校验 hostToken → 直接恢复隧道（App 侧收 host/online 事件）
  僵尸接管：若中继上同 hostId 的旧隧道已沉默超过 staleHostAfter（45s，即
  连 30s 一次的 ping 都不再应答，典型为 TCP 半开/睡眠唤醒），持有效
  hostToken 的重连**直接顶替**旧隧道，不再等 90s 死链判定；若旧隧道仍然
  活跃则拒绝（防重复 bridge 进程互踢）

Device:
  connect(Authorization: Bearer sessionToken)
  有效 → 隧道就绪；无效/过期 → 403 → App 用 refreshToken 换新会话重连
  断线 → 指数退避重连；App 前台/后台服务持续（应用内通知依赖此连接）

中继：
  Host/Device 任一端离线 → 对端收到控制帧 host/offline 或 device/offline
  Host 离线期间 Device 的 rpc → 立即回 rpc-reply {transport:true, error:{code:"host-offline"}}
```

---

## 5. 错误码表

| code | HTTP | 含义 | 处理 |
| --- | --- | --- | --- |
| `unauthorized` | 401 | token 缺失/无效/过期 | App 换 token 重连 |
| `forbidden` | 403 | 会话已吊销/未绑定 | 重新配对 |
| `pair-invalid` | 409 | **统一配对失败码**（PIN 错/已过期/已被消费/设备不存在）——错误码刻意不细分，防止探测 hostId 与 PIN 状态 | 提示重输或重新开启配对 |
| `host-conflict` | (WSS close) | 匿名重注册已存在的 hostId 被拒（劫持保护） | 用持久化的 hostToken 重连 |
| `weak-pin` | (WSS close) | 固定 PIN 过于简单被拒 | 在电脑端设置中更换 |
| `rate-limited` | 429 | 请求过频（pair/register 每 IP 限速） | 退避重试 |
| `host-offline` | 409 | 目标 Host 不在线 | App 显示离线，自动重试 |
| `host-replaced` | 409 | 同 Host 新连接顶替 | 旧连接关闭（正常） |
| `device-limit` | 409 | 绑定设备超限 | 在 Host 端解绑 |
| `unknown-channel` | 404 | 帧 channel 不存在 | 忽略并重连 |
| `overflow` | — | 队列溢出（隧道层） | 重开 channel |
| `relay-error` | 500 | 中继内部错误 | 重试，报告 |

---

## 6. 安全细则

1. **传输**：WSS（TLS 1.2+）；App 固定中继证书公钥（certificate pinning，防私有 DNS/中间人）。
2. **Host 出站**：双向 TLS 可选（自签 CA 分发给 bridge；默认单向 + hostToken）。
3. **Token**：
   - `hostToken` / `sessionToken` / `refreshToken` 均为 256-bit 随机；中继只存 SHA-256 哈希。
   - `sessionToken` 24h 有效；`refreshToken` 30 天、单次使用（轮换）。
   - 吊销即时生效（中继内存缓存吊销清单）。
4. **PIN**：6 位数字；10 分钟时效；单次；5 次错误锁定 15 分钟。
5. **限速**：pair 5 req/min/IP；rpc 60 req/min/device；sse-open 10/min/device。
6. **审计**：中继记录配对、吊销、Host 上线/下线（不记录业务载荷；SSE/RPC body 不落盘）。

---

## 7. 实现清单（按依赖排序）

1. 中继 Go：WSS 端点（host/device）、控制面（register/pair/refresh/revoke）、channel 多路复用转发、心跳、内存态（后续换 SQLite）。
2. bridge Node：出站 WSS + register（携带壳生成的 hostId）+ 隧道帧 ⇄ dsh web（RPC/SSE/respond 透传）+ PIN 输出（stdout JSON，壳读取展示）。
3. App Flutter：pair 流程（deviceId+PIN）+ device WSS + 事件子集渲染 + 审批应答 + 重连。
4. 壳集成：三平台「远程连接」菜单 → 生成 13 位设备 ID + 二维码（`relay://<relay>/pair?device=<ID>`）→ spawn bridge 注册 → 注册成功展示二维码/PIN，失败提示中继不可用。

## 8. 待定（开工前冻结）

- [ ] 中继公网域名与 TLS 证书来源（Let's Encrypt / 已有证书）
- [ ] `refresh` 端点路径（本稿 `pair/refresh`，可并入 `session/refresh`）
- [ ] 事件子集是否需要 Host 侧过滤（减少 App 流量）——默认透传，App 端过滤

## 9. 连接模式（2026-08 起：外网一律走中继）

两级连接模式：① 内网直连（bridge LAN 代理 `0.0.0.0:13080` → 本机 dsh）→
② 其余全部走中继隧道。

**WebRTC P2P 已移除**（v1.1.7 起）：手机 flutter_webrtc ↔ 电脑 bridge
werift 的 P2P 数据通道整体删除——werift 及其媒体依赖（mediabunny 等约
26 MB）不再随 bridge 打包，`signal` 信令帧不再收发，手机端不再发起
P2P 升级（「屏蔽 P2P」开关与连接指示一并移除）。外网流量只经 relay
隧道（§5 的 http/rpc/sse 帧），局域网内则优先 bridge LAN 直连代理。

### 9.1 relay 连接保活（2026-08 修复）

- relay 对 host/device 发文本 `{"v":1,"type":"ping"}`，对端回文本 pong。
- **文本 pong 必须刷新读超时**（relay 的 SetPongHandler 只认协议层 pong，
  否则 90s 读超时踢掉 host 且因 socket 未关闭造成半开 → host-offline 永续）。
- host handler 退出必须 `defer ws.Close()`（防连接泄漏）。
