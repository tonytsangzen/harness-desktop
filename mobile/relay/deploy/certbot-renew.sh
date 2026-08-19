#!/usr/bin/env bash
# Let's Encrypt 证书自动续期（供 systemd timer / cron 定时调用，幂等）
#
# - 只续期临近过期（≤30 天）的证书，平时秒退、无副作用
# - nginx 插件会在成功续期后自动 reload nginx，新证书立即生效
# - certbot renew 默认复用私钥 → 公钥(SPKI)不变 → 手机 App 的
#   证书固定（certificate pinning）不受影响，无需重新配对
#   （仅密钥泄露等场景才需要强制换钥: certbot renew --renew-with-new-key，
#    注意那会改变 SPKI，手机端需同步更新 pin 后才能连上）
#
# 安装（systemd timer，每天 00:00 / 12:00 各一次 + 随机延迟）:
#   sudo install -m 755 certbot-renew.sh /usr/local/sbin/certbot-renew.sh
#   sudo install -m 644 harness-relay-certbot.{service,timer} /etc/systemd/system/
#   sudo systemctl daemon-reload && sudo systemctl enable --now harness-relay-certbot.timer
#
# 无 systemd 的环境用 cron（root）:
#   17 3,15 * * * root /usr/local/sbin/certbot-renew.sh
set -euo pipefail

LOG="/var/log/harness-relay-certbot.log"
STAMP="$(date '+%Y-%m-%d %H:%M:%S')"

if ! command -v certbot >/dev/null 2>&1; then
  echo "$STAMP certbot 未安装，跳过续期" >>"$LOG"
  exit 0
fi

echo "$STAMP certbot renew 开始" >>"$LOG"
if certbot renew --quiet >>"$LOG" 2>&1; then
  echo "$STAMP 完成（无到期证书时无任何续期动作）" >>"$LOG"
else
  echo "$STAMP 续期失败，请检查上方日志" >>"$LOG"
  exit 1
fi
