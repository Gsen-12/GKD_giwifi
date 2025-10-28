#!/bin/sh
# ==============================================================
# File: /etc/giwifi-lan.sh
# Author: <Your Name or GitHub ID>
# Description:
#   GiWiFi 校园网自动登录脚本（兼容 BusyBox 环境）
#   支持自动加密认证、设备自动绑定（isRebind）、失败重试
# ==============================================================
# ✅ 兼容环境:
#   - OpenWrt / Linux / BusyBox Shell (ash/sh)
# ✅ 依赖项 (需预装):
#   - curl        (HTTP 请求)
#   - openssl     (AES-128-CBC 加密)
#   - xxd / hexdump / od  (字符串转16进制)
# ✅ 固定参数:
#   USERIP 固定为 10.12.19.78 （按需修改）
# ==============================================================
# 使用方法：
#   chmod +x /etc/giwifi-lan.sh
#   /etc/giwifi-lan.sh <手机号> <密码> <网关IP>
#
# 示例：
#   /etc/giwifi-lan.sh 19120486918 mypassword 192.168.99.2
#
# 启动项（开机自动执行）：
#   在 /etc/rc.local 中添加：
#     /etc/giwifi-lan.sh 19120486918 mypassword 192.168.99.2 &
# ==============================================================

USERNAME="$1"
PASSWORD="$2"
BASEURL="$3"

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$BASEURL" ]; then
  echo "Usage: $0 <username> <password> <portal_ip>"
  exit 1
fi

# ==============================================================
# 基本配置
# ==============================================================
USERIP="10.12.19.78"  # 固定用户IP，可根据实际情况修改
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'

LOGIN_HTML="/tmp/login.html"
LAST_RESP="/tmp/giwifi_last_resp.json"

# --------------------------------------------------------------
# 日志函数
# --------------------------------------------------------------
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [giwifi-lan.sh] - $*"
}

# --------------------------------------------------------------
# 工具函数：字符串转十六进制
# --------------------------------------------------------------
str2hex() {
  if command -v hexdump >/dev/null 2>&1; then
    echo -n "$1" | hexdump -v -e '/1 "%02x"'
  elif command -v xxd >/dev/null 2>&1; then
    echo -n "$1" | xxd -p -c 9999
  else
    echo -n "$1" | od -An -t x1 | tr -d ' \n'
  fi
}

# --------------------------------------------------------------
# 工具函数：十六进制转二进制
# --------------------------------------------------------------
hex_to_bin_printf() {
  HEX="$1"
  ESCAPED=$(echo -n "$HEX" | sed 's/../\\x&/g')
  printf "%b" "$ESCAPED"
}

# ==============================================================
# (1) 获取登录页，提取加密参数 (iv, sign, pid, vlan等)
# ==============================================================
LOGIN_URL="http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX"
log "Fetching login page: $LOGIN_URL"

curl -s -A "$UA" -H "Referer: http://${BASEURL}/" "$LOGIN_URL" -o "$LOGIN_HTML"

if [ ! -s "$LOGIN_HTML" ]; then
  log "❌ 获取登录页失败，文件为空"
  exit 1
fi

# 提取参数
IV=$(sed -n 's/.*id="iv" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
SIGN=$(sed -n 's/.*name="sign" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
PID=$(sed -n 's/.*name="pid" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
PORTAL=$(sed -n 's/.*name="portalTemplateId" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
VLAN=$(sed -n 's/.*name="vlan" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)

log "Extracted iv=${IV:-<empty>}, sign=${SIGN:-<empty>}, pid=${PID:-<empty>}, portal=${PORTAL:-<empty>}, vlan=${VLAN:-<empty>}"

if [ -z "$IV" ]; then
  log "❌ 未能获取 iv，可能是页面结构变化"
  exit 1
fi

# ==============================================================
# (2) 组装明文并加密 (AES-128-CBC, 无填充)
# ==============================================================
PLAIN="name=${USERNAME}&password=${PASSWORD}&nasName=GKDX&userIp=${USERIP}&pid=${PID}&vlan=${VLAN}&sign=${SIGN}&portalTemplateId=${PORTAL}&show_type=0"
log "Plaintext length: $(printf '%s' \"$PLAIN\" | wc -c) bytes"

HEX_PLAIN=$(str2hex "$PLAIN")
BYTES_LEN=$(echo -n "$HEX_PLAIN" | wc -c)
DATLEN=$((BYTES_LEN / 2))
PAD_BYTES=$(( (16 - (DATLEN % 16)) % 16 ))

# 填充 00 到 16字节对齐
PAD_HEX=""
i=0
while [ $i -lt $PAD_BYTES ]; do
  PAD_HEX="${PAD_HEX}00"
  i=$((i+1))
done
HEX_PLAIN_PAD="${HEX_PLAIN}${PAD_HEX}"

KEY_STR="1234567887654321"
KEY_HEX=$(str2hex "$KEY_STR")
IV_HEX=$(str2hex "$IV")

# 若 IV 不足 16 字节，右补 00
IV_BYTES_LEN=$(( $(echo -n "$IV" | wc -c) ))
if [ $IV_BYTES_LEN -lt 16 ]; then
  PADN=$((16 - IV_BYTES_LEN))
  j=0
  while [ $j -lt $PADN ]; do
    IV_HEX="${IV_HEX}00"
    j=$((j+1))
  done
fi

BIN_PLAIN="$(hex_to_bin_printf "$HEX_PLAIN_PAD")"

ENC_BASE64=$(printf "%s" "$BIN_PLAIN" | openssl enc -aes-128-cbc -K "$KEY_HEX" -iv "$IV_HEX" -nopad -base64)

if [ -z "$ENC_BASE64" ]; then
  log "❌ openssl 加密失败"
  exit 1
fi
log "Encrypted Base64 length: $(printf '%s' \"$ENC_BASE64\" | wc -c)"

# ==============================================================
# (3) 发起登录请求 (自动处理绑定/重试逻辑)
# ==============================================================
AUTH_URL="http://${BASEURL}/gportal/web/authLogin?round=$((RANDOM%1000))"
log "POSTing to $AUTH_URL"

RESP=$(curl -s -A "$UA" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Origin: http://${BASEURL}" \
  -H "Referer: $LOGIN_URL" \
  --data-urlencode "data=${ENC_BASE64}" \
  --data-urlencode "iv=${IV}" \
  "$AUTH_URL")

echo "$RESP" > "$LAST_RESP"
log "Server response: $RESP"

RESULT=$(echo "$RESP" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

# --------------------------------------------------------------
# 登录成功
# --------------------------------------------------------------
if [ "$RESULT" = "0" ]; then
  log "✅ 登录成功"
  exit 0
fi

# --------------------------------------------------------------
# 检测绑定冲突（resultCode=2）
# --------------------------------------------------------------
if [ "$RESULT" = "2" ]; then
  log "⚠️ 检测到设备绑定冲突 (resultCode=2)，尝试重新绑定"
  BINDMAC=$(echo "$RESP" | sed -n 's/.*"bindmac":"\([^"]*\)".*/\1/p')
  log "原绑定设备 MAC: ${BINDMAC:-未知}"
  sleep 5

  # 尝试 isRebind 模式
  AUTH_URL_REBIND="http://${BASEURL}/gportal/web/authLogin?isRebind=true&round=$((RANDOM%1000))"
  log "POSTing rebind request..."
  RESP2=$(curl -s -A "$UA" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: http://${BASEURL}" \
    -H "Referer: $LOGIN_URL" \
    --data-urlencode "data=${ENC_BASE64}" \
    --data-urlencode "iv=${IV}" \
    "$AUTH_URL_REBIND")

  echo "$RESP2" > "$LAST_RESP"
  RESULT2=$(echo "$RESP2" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

  # 若仍绑定失败，尝试 reBind=true
  if [ "$RESULT2" = "2" ]; then
    log "⚠️ 尝试使用 reBind=true 模式..."
    AUTH_URL_REBIND2="http://${BASEURL}/gportal/web/authLogin?isRebind=true&reBind=true&round=$((RANDOM%1000))"
    RESP2=$(curl -s -A "$UA" \
      -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
      -H "Origin: http://${BASEURL}" \
      -H "Referer: $LOGIN_URL" \
      --data-urlencode "data=${ENC_BASE64}&reBind=true" \
      --data-urlencode "iv=${IV}" \
      "$AUTH_URL_REBIND2")
    echo "$RESP2" > "$LAST_RESP"
    RESULT2=$(echo "$RESP2" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
  fi

  if [ "$RESULT2" = "0" ]; then
    log "✅ 成功重新绑定设备"
  else
    log "⚠️ reBind 请求返回 code=$RESULT2，继续尝试登录"
  fi

  sleep 5
  AUTH_URL_FINAL="http://${BASEURL}/gportal/web/authLogin?round=$((RANDOM%1000))"
  log "POSTing final login..."
  RESP3=$(curl -s -A "$UA" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: http://${BASEURL}" \
    -H "Referer: $LOGIN_URL" \
    --data-urlencode "data=${ENC_BASE64}" \
    --data-urlencode "iv=${IV}" \
    "$AUTH_URL_FINAL")

  echo "$RESP3" > "$LAST_RESP"
  RESULT3=$(echo "$RESP3" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

  if [ "$RESULT3" = "0" ]; then
    log "✅ 自动绑定 + 登录完成"
    exit 0
  else
    log "❌ 最终登录失败 (code=${RESULT3:-<none>})"
    exit 4
  fi
fi

# --------------------------------------------------------------
# 其他错误
# --------------------------------------------------------------
log "❌ 登录失败 (resultCode=${RESULT:-<none>})，响应内容保存在 $LAST_RESP"
exit 2

# ==============================================================
# 📘 调试建议：
#   1. 检查依赖是否存在：
#        which curl openssl xxd hexdump od
#   2. 调试输出：
#        sh -x /etc/giwifi-lan.sh <user> <pass> <ip>
#   3. 若 iv 无法解析，可能是 portal 页面模板更新
# ==============================================================

