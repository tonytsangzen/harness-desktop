# 手机 App 实时查询 / 远程操作 Agent — 架构设计（v3：定型）

> 需求决策（全部确认）：① 原生 App，**先 Android**（Flutter）② 包含审批/提问应答 ③ 出网远程访问 ④ 认证 = token + 扫码 + HTTPS + PIN ⑤ 自建 **Go 中继**（VPS）⑥ **仅应用内推送**（不做 APNs/FCM 锁屏推送）⑦ **只走中继**（不做局域网直连）⑧ 审批**免二次 PIN**。
> 架构：自建云中继（主机出站隧道）+ 主机桥接层（Node）+ Flutter App（Android 优先）。

---

## 1. 数据面结论（复用 v1 调研，dsh web 0.1.0-rc.6 实测）

- **RPC**：`POST /api/<method>`（`session.list` 含 `running`、`session.history`、`subagent.list`、`goal.*`、`host.describe`）
- **实时**：SSE `/api/events.mux`（`step/start|end`、`assistant/chunk`、`tool/call|result`、`approval/requested|resolved`、`session/jobs`、`session/queue`…）+ `/api/events.host`（running 翻转）
- **应答**：`POST /api/respond`（审批/提问应答，**支持远程审批**）
- **约束**：dsh web 无鉴权（信任围栏非认证层）→ 任何对外暴露都必须有独立认证层；dsh web 保持 127.0.0.1 不动

---

## 2. 总体架构

```
┌─ 手机 App（Flutter，Android 优先）───────┐
│ · 扫码配对（relay 地址 + device token + PIN）│
│ · 会话列表 / running 状态                   │
│ · 实时执行流（步骤、文本、工具）            │
│ · 审批 / 提问应答（远程批准、回答问题）      │
│ · 后台任务 / 子代理 / goal 状态             │
│ · 应用内通知（App 存活时经 WSS 收事件 →     │
│   本地通知；不做 APNs/FCM 锁屏推送）         │
└──────────────┬─────────────────────────────┘
               │ HTTPS / WSS（TLS，正式证书）
               │ 每请求鉴权：Authorization + 会话 token
┌──────────────▼─────────────────────────────┐
│ 云中继（自建 VPS，Go）                     │
│ · 控制面：设备注册、PIN 配对、token 签发/吊销│
│ · 数据面：App ↔ Host 双向隧道（WSS 多路复用）│
└──────────────┬─────────────────────────────┘
               │ WSS 出站长连接（NAT 穿透，免公网 IP）
┌──────────────▼─────────────────────────────┐
│ 主机桥接层 dsh-mobile-bridge（Node）        │
│ · 壳「远程连接」开启时 spawn，随壳退出      │
│ · 出站连中继，注册设备、展示配对码/PIN      │
│ · 隧道解复用 → 127.0.0.1 dsh web           │
└──────────────┬─────────────────────────────┘
               │ 127.0.0.1 明文（仅本机可见）
┌──────────────▼─────────────────────────────┐
│ dsh web（--host 127.0.0.1 --port N）        │
│  POST /api/*  RPC + SSE events.*            │
└────────────────────────────────────────────┘
```

**为什么自建中继而非 Tailscale/frp**：
- Tailscale 的认证体系是账号制，无法融入「token+扫码+PIN」自管体系，App 内嵌其 SDK 复杂且受其策略约束；
- frp/cloudflared 解决隧道但认证、配对、审批 RPC、推送都要另起一套；
- 自建中继（单 VPS + 一个 Go 服务）把**隧道 + 认证 + 配对**收在一个可控组件里，与我们的协议完全对齐。

**已决策不做**：APNs/FCM 锁屏推送（仅应用内通知）、局域网直连降级（只走中继）、审批二次 PIN。

---

## 3. 组件设计

### 3.1 云中继（relay）

| 项 | 设计 |
| --- | --- |
| 技术栈 | **Go**（单二进制、低内存，适合长期线上） |
| 传输 | WSS（TLS + Let's Encrypt）；App 校验正式证书 |
| 身份模型 | `Host`（电脑）↔ `Device`（手机）一对一绑定，一个 Host 可绑多 Device |
| 控制面 API | `POST /relay/v1/register`（Host 出站注册，返回 device token）、`POST /relay/v1/pair`（Device：device token + PIN → 会话 token）、`POST /relay/v1/revoke` |
| 数据面 | Host 与 Device 各持一条 WSS；中继按 channel 多路复用转发（RPC / SSE / 应答）；Host 离线 → Device 端标记离线并缓存待推送事件 |
| PIN | 中继签发、短时效（如 10 分钟）、单次使用；错误尝试限速（如 5 次锁定） |
| 存储 | SQLite：hosts、devices、bindings、sessions（token 仅存哈希）；可无状态部署 + Redis（扩展时） |

### 3.2 主机桥接层（dsh-mobile-bridge，Node）

| 项 | 设计 |
| --- | --- |
| 启动 | 壳菜单「远程连接」→ spawn bridge（复用自动安装的 node）；端口/地址零配置（出站模式） |
| 注册与配对 | 连中继 → 注册 Host → 获得一次性 `pairToken` + `PIN`（中继生成）→ 壳 UI 显示二维码（`relay://<relay>/pair?t=<pairToken>&pin=<PIN>`）+ PIN 大字 |
| 隧道 | 单条 WSS 出站；帧协议：`{channel, kind: rpc|sse|respond, path, payload}`；SSE 流按 channel 推帧 |
| 转发 | 对 dsh web 127.0.0.1 发起 RPC / 打开 SSE / respond；流控与背压（SSE 大体积帧 → chunk 化） |
| 安全 | 出站 TLS 双向校验（pin 中继证书）；本地不落盘 token；随壳退出终止（进程组） |

### 3.3 手机 App（Flutter）

| 模块 | 设计 |
| --- | --- |
| 配对流 | 扫码（相机）解析 `relay://` URL → 输 PIN → 换会话 token → 安全存储（iOS Keychain / Android Keystore）→ 自动重连 |
| 会话列表 | `session.list`（running 标记、updatedAt 排序） |
| 实时执行视图 | `events.mux` + `events.host`（fetch 流式 / dart `WebSocket`+ 帧解析）：步骤流、文本/推理流式渲染、工具调用卡片（含结果）、审批横幅 |
| 审批/提问 | `approval/requested` / `question/requested` 弹卡片 → 同意/拒绝/回答 → `POST /api/respond`（经中继） |
| 任务/子代理/goal | `session/jobs` 帧、`subagent.list`、`goal.*` |
| 应用内通知 | App 存活时（前台/后台服务）经 WSS 实时收事件，对「agent 完成 / 需要审批 / 任务结束」弹 Android 本地通知（NotificationChannel，无需 FCM）；App 被系统杀死后不保证送达（已决策不做 APNs/FCM） |
| 网络健壮性 | 断线指数退避重连；会话按 `seq` 去重；Wi-Fi/蜂窝切换自动恢复 |

### 3.4 认证与安全（四层，全链路）

1. **传输层**：中继 TLS（正式证书）；App 校验证书链；Host 出站 TLS 双向校验。
2. **设备 token**：扫码获得一次性 `pairToken`（带短时效），换长期 `device token`（哈希存中继）。
3. **PIN**：电脑屏幕显示、手机输入；单次有效 + 时效 + 限速防爆破；配对成功后立即失效。
4. **每请求鉴权**：App 每个中继请求带会话 token；中继校验后才向 Host 转发；Host 侧再按 channel 白名单（仅 `/api/*`）放行。
   - 附加：审批类 RPC（`session.prompt`、`approval` 应答）可要求 PIN 二次确认（可选开关）。

### 3.5 关键时序

```
配对：
 Host(bridge) ──register──▶ Relay ──pairToken+PIN──▶ Host UI(二维码+PIN)
 App ──扫码(pairToken+PIN)──▶ Relay ──校验──▶ device token ──▶ App 存储
连接：
 App ──WSS + session token──▶ Relay ◀──WSS── Host(bridge) ◀──127.0.0.1── dsh web
实时：
 App ◀──SSE 帧(step/tool/approval/jobs)── Relay ◀── 隧道帧 ◀── bridge ◀── events.mux/host
审批：
 App ──respond 帧──▶ Relay ──▶ bridge ──POST /api/respond──▶ dsh web
```

---

## 4. 分阶段落地

| 阶段 | 内容 | 关键交付 | 依赖 |
| --- | --- | --- | --- |
| P0 | 中继 + 桥接层 + Flutter App（Android）最小可用 | 配对（扫码+PIN）、会话列表、实时执行流、**审批/提问应答**、断线重连、应用内通知 | VPS 一台（可 2C1G）；dsh 壳加「远程连接」菜单（三平台） |
| P1 | 体验与扩展 | 多设备绑定、token 吊销管理、Android 前台服务保活（应用内通知更可靠）、iOS 版（App Store） | 如需 iOS 则注册 Apple 开发者账号 |
| P2 | 规模化 | 多 Host（中继多租户隔离）、审计日志、用量配额、Google Play 上架 | 上架合规、加固（混淆/防抓包） |

**工作量估算**：P0 中继（Go ~800 行）+ bridge（Node ~400 行）+ App（~3k 行）+ 壳集成（三平台各 ~100 行）。

---

## 5. 已确认决策汇总

1. 客户端：原生 App（Flutter），**先 Android**。
2. 范围：包含审批/提问应答（`/api/respond` 远程应答），审批**免二次 PIN**。
3. 网络：出网远程访问，**只走中继**（不做局域网直连）。
4. 认证：token + 扫码 + HTTPS + PIN（四层安全）。
5. 中继：自建 VPS + **Go**。
6. 推送：**仅应用内通知**（不做 APNs/FCM 锁屏推送）。

---

## 附录：协议草案（下一步）

P0 实施前需先冻结三端（中继 / bridge / App）共享协议：

1. **配对协议**：`register`（Host→Relay）→ `pair`（Device：pairToken+PIN → session token）→ `revoke`。
2. **隧道帧**：`{channel, kind: rpc|sse|respond, path, payload, seq?}`；SSE 按 channel 流式转发；RPC 请求/响应带 `rpcId` 关联。
3. **事件子集**（App 消费）：`session/event`（step/assistant/tool/approval）、`session/subscribed`、`session/jobs`、`session/queue`、`approval/requested|resolved`、`question/requested|resolved`、Host 在线/离线状态。
4. **安全**：TLS 证书固定（App 侧 pin relay 证书）、token 轮换（会话 token 短时效 + 刷新）、限速。

