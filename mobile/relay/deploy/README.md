# relay 免费部署指南

relay 是 Go 单文件无状态中继（WebSocket 长连接转发），对部署平台的要求：
**必须支持长连接**（排除会休眠的免费 PaaS 层）、**必须提供 TLS**（手机端走 WSS）。

| 路线 | 成本 | 特点 | 适合 |
|---|---|---|---|
| **A. Oracle Cloud 永久免费 VPS** | 0（永久） | Arm 4核24G / AMD 1核1G，可选日本/新加坡机房 | 长期稳定使用（推荐） |
| **B. Cloudflare Tunnel** | 0（需域名） | relay 跑自己电脑，隧道暴露 WSS | 不想买服务器、电脑常开 |
| **C. 国内云免费试用** | 0（限期） | 阿里云/腾讯云轻量新用户免费额度 | 快速验证、延迟最低 |

---

## 路线 A：Oracle Cloud 免费 VPS（推荐）

1. 注册 [Oracle Cloud](https://www.oracle.com/cloud/free/)（需国际信用卡验证，选 **Japan East / Singapore** 区域）
2. 创建实例：Ubuntu 24.04，Arm 或 AMD 免费规格
3. 域名 A 记录指向实例公网 IP（没有域名可先用 IP 测试，TLS 之后再配）

```bash
# 装 docker
curl -fsSL https://get.docker.com | sh
# 克隆仓库（或只拷 mobile/relay 目录）
# 改 deploy/Caddyfile 里的域名
cd harness-desktop/mobile/relay
docker compose -f deploy/docker-compose.yml up -d --build
```

- 手机端 relay 地址填：`https://relay.example.com`
- 验证：`curl https://relay.example.com/relay/healthz` → `ok`（nginx 只反代 /relay/ 路径；`/healthz` 仅容器内/本机直连用）

> 若大陆网络连不上 Let's Encrypt 的 http-01 验证（80 端口被封），改用 Caddy 的 DNS-01：
> 在 Caddyfile 加 `tls { dns cloudflare <api_token> }`，并把 `80:80` 端口映射去掉。
> 参考 https://caddyserver.com/docs/automatic-https#dns-challenge

### 国内网络：Docker Hub 拉取超时

大陆访问 Docker Hub 经常超时，两种解决方式（任选）：

**方式 1：构建时换镜像源**（不改系统配置）
```bash
docker build -f deploy/Dockerfile \
  --build-arg GO_IMAGE=m.daocloud.io/library/golang:1.26-alpine \
  --build-arg RUN_IMAGE=m.daocloud.io/library/alpine:3.21 \
  -t dsh-relay .
docker compose -f deploy/docker-compose.yml up -d
```
> `m.daocloud.io` 之外可用的加速源：`docker.1ms.run`、`dockerproxy.com`、阿里云容器镜像服务（个人加速地址）。

### 不用 Docker 直接跑（更省内存）

```bash
# 本机编译静态二进制（或下载已有产物）
cd mobile/relay && CGO_ENABLED=0 go build -o relay .
# systemd 服务
sudo tee /etc/systemd/system/dsh-relay.service >/dev/null <<'EOF'
[Unit]
Description=dsh-mobile relay
After=network.target
[Service]
ExecStart=/usr/local/bin/dsh-relay
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
sudo install -m755 relay /usr/local/bin/dsh-relay
sudo systemctl enable --now dsh-relay
```

---

## 路线 B：Cloudflare Tunnel（零服务器）

前提：有域名（cloudflare.com 托管的域名，几块钱/年），relay 跑在自己电脑。

```bash
# 电脑上正常跑 relay
./relay

# 方式1: 快速隧道（无需域名配置, 域名随机）
cloudflared tunnel --url http://127.0.0.1:8443
# -> 得到 https://xxxx.trycloudflare.com

# 方式2: 固定域名（推荐, 手机端地址稳定）
# 在 Cloudflare 面板 -> Zero Trust -> Networks -> Tunnels 创建隧道
# Public Hostname: relay.example.com -> http://127.0.0.1:8443
cloudflared tunnel run <tunnel-id>
```

- 手机端 relay 地址填：`https://relay.example.com`
- TLS 由 Cloudflare 边缘自动提供，电脑端无需证书
- 注意：电脑关机则中继不可用

---

## 路线 C：国内云免费试用

- 阿里云 / 腾讯云 / 华为云 新用户都有免费试用轻量服务器（1-3 个月）
- 与路线 A 完全相同的部署方式（Docker Compose 或二进制 + systemd）
- 国内机房延迟最低，且 80/443 端口不受大陆网络限制，Let's Encrypt 正常签发
- 到期后付费（轻量 ~¥50/月）或迁移

---

## 手机端配置

配对二维码里 relay 参数填部署后的地址（`https://...`），电脑端 bridge 启动参数：
`--relay wss://relay.example.com`（WSS）。

桥接端无需开放任何入站端口（bridge 主动出站连 relay）。

---

## 注意事项

1. **内存存储**：relay 的配对/设备数据只存在内存，**重启后手机需重新扫码配对**。
   想要持久化：给 relay 加一个 `--data /path/store.json`（可落盘），当前版本未实现，重启后用
   `pair/refresh` 无法恢复（token 也在内存），直接重新配对即可。
2. **单实例**：relay 为单机内存 hub，不需要多副本；多个设备连同一个实例即可。
3. **健康检查**：`/relay/healthz`（及本机直连 `/healthz`）返回 `ok`，供负载均衡/平台探活。
4. **防火墙**：VPS 需放行 80/443（Docker 映射）；若只用 Caddy 反代则 8443 不必对外。
5. **日志**：`docker compose logs -f relay`；日志里有 host/device 的注册、转发与断开记录，便于排障。
