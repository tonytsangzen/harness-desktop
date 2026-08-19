#!/usr/bin/env bash
# 中继服务器 Let's Encrypt 证书申请脚本（nginx 反代路线，Ubuntu/Debian）
#
# 申请成功后 certbot 会自动改写 nginx 配置（填入证书路径）并 reload，
# HTTPS/WSS 立即生效，无需手工编辑 nginx.conf。
#
# 用法:
#   sudo ./certbot-issue.sh -e you@example.com              # 默认域名 relay.deepvisus.top
#   sudo ./certbot-issue.sh -d relay.example.com -e you@example.com
#   sudo ./certbot-issue.sh -d relay.example.com -e you@example.com -m standalone
#
# 前置条件:
#   1) apt install nginx certbot python3-certbot-nginx
#   2) 域名 A 记录已指向本机公网 IP，80/443 对公网可达
#      （大陆网络若 80 端口被封导致 http-01 失败，见 README「DNS-01」一节，
#        或改用 Caddy 路线 —— Caddy 自动管理证书，不需要本脚本）
#   3) 本脚本幂等：证书已存在时直接退出，不会重复申请
#
# 申请后安装自动续期（每天两次，systemd timer）:
#   sudo install -m 755 certbot-renew.sh /usr/local/sbin/certbot-renew.sh
#   sudo install -m 644 harness-relay-certbot.{service,timer} /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now harness-relay-certbot.timer
set -euo pipefail

DOMAIN="relay.deepvisus.top"
EMAIL=""
MODE="nginx"   # nginx | standalone | webroot

usage() {
  sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN="$2"; shift 2 ;;
    -e|--email) EMAIL="$2"; shift 2 ;;
    -m|--mode) MODE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "未知参数: $1（-h 查看帮助）" >&2; exit 1 ;;
  esac
done

[[ -z "$EMAIL" ]] && { echo "错误: 缺少邮箱，用 -e you@example.com 指定（证书过期提醒用）" >&2; exit 1; }
command -v certbot >/dev/null 2>&1 || { echo "错误: 未安装 certbot，请先 apt install certbot python3-certbot-nginx" >&2; exit 1; }

LIVE="/etc/letsencrypt/live/$DOMAIN"
if [[ -f "$LIVE/fullchain.pem" ]]; then
  echo "证书已存在: $LIVE —— 跳过申请（幂等）。"
  echo "剩余天数:"
  certbot certificates 2>/dev/null | grep -A1 "$DOMAIN" || true
  echo "自动续期已由 harness-relay-certbot.timer 负责（见 certbot-renew.sh）。"
  exit 0
fi

case "$MODE" in
  nginx)
    # nginx 插件：申请后自动改写 nginx 配置并 reload，最省事
    certbot --nginx -d "$DOMAIN" -m "$EMAIL" \
      --agree-tos --no-eff-email --non-interactive
    ;;
  standalone)
    # 需要 80 端口空闲（nginx 若占用 80，先 systemctl stop nginx，申请完再 start）
    certbot certonly --standalone --preferred-challenges http --http-01-port 80 \
      -d "$DOMAIN" -m "$EMAIL" \
      --agree-tos --no-eff-email --non-interactive
    ;;
  webroot)
    # 已有静态站占 80 时用 webroot；-w 路径需存在且 nginx 能服务 /.well-known
    certbot certonly --webroot -w /var/www/html \
      -d "$DOMAIN" -m "$EMAIL" \
      --agree-tos --no-eff-email --non-interactive
    ;;
  *) echo "错误: 未知模式 $MODE（nginx | standalone | webroot）" >&2; exit 1 ;;
esac

echo
echo "✓ 证书已就绪: $LIVE/fullchain.pem"
echo "  验证: curl https://$DOMAIN/relay/healthz  →  ok"
echo "  续期: 安装 certbot-renew.sh + harness-relay-certbot.timer（见本文件头部注释）"
echo "  提示: renew 默认复用私钥，手机 App 的证书固定(SPKI pin)不会失效"
