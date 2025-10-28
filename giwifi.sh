#!/bin/sh
# /etc/giwifi-lan.sh
# 自动登录脚本（BusyBox 兼容，纯 shell + openssl）
# USERIP 固定为 10.11.202.124
# Usage: /etc/giwifi-lan.sh <username> <password> <portal_ip>
# Dependencies: curl, openssl, xxd (or od)

USERNAME="$1"
PASSWORD="$2"
BASEURL="$3"

if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ] || [ -z "$BASEURL" ]; then
  echo "Usage: $0 <username> <password> <portal_ip>"
  exit 1
fi

# 固定 USERIP（按你要求固定值）
USERIP="10.12.19.78"

# 完整的浏览器 User-Agent（从你抓包中使用的 UA）
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'

LOGIN_HTML="/tmp/login.html"
LAST_RESP="/tmp/giwifi_last_resp.json"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [giwifi-lan.sh] - $*"
}

# portable: string -> hex (each byte two hex digits)
str2hex() {
  # Try hexdump/hexdump -v -e works on many systems
  if command -v hexdump >/dev/null 2>&1; then
    echo -n "$1" | hexdump -v -e '/1 "%02x"'
  elif command -v xxd >/dev/null 2>&1; then
    echo -n "$1" | xxd -p -c 9999
  else
    # fallback to od
    echo -n "$1" | od -An -t x1 | tr -d ' \n'
  fi
}

# hex -> binary (print binary data from hex string)
hex_to_bin_printf() {
  # We will produce a printf argument with \xHH sequences
  HEX="$1"
  # Insert \x before every two hex chars
  ESCAPED=$(echo -n "$HEX" | sed 's/../\\x&/g')
  # Use printf "%b" to expand back to binary
  printf "%b" "$ESCAPED"
}

# 1) fetch login page (use UA, ensure we get the same page)
LOGIN_URL="http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX"
log "fetching login page: $LOGIN_URL"
curl -s -A "$UA" -H "Referer: http://${BASEURL}/" "$LOGIN_URL" -o "$LOGIN_HTML"

if [ ! -s "$LOGIN_HTML" ]; then
  log "❌ failed to fetch login page or file empty"
  exit 1
fi

# 2) extract iv, sign, pid, portalTemplateId, vlan (BusyBox-friendly)
IV=$(sed -n 's/.*id="iv" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
SIGN=$(sed -n 's/.*name="sign" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
PID=$(sed -n 's/.*name="pid" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
PORTAL=$(sed -n 's/.*name="portalTemplateId" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)
VLAN=$(sed -n 's/.*name="vlan" value="\([^"]*\)".*/\1/p' "$LOGIN_HTML" | head -n1)

log "extracted iv: ${IV:-<empty>}, sign: ${SIGN:-<empty>}, pid: ${PID:-<empty>}, portalId: ${PORTAL:-<empty>}, vlan: ${VLAN:-<empty>}"

if [ -z "$IV" ]; then
  log "❌ 未能获取 iv，登录页可能访问失败或解析模式不匹配"
  exit 1
fi

# 3) Build plaintext form string exactly as frontend serializes
# Note: your frontend used $("#frmLogin").serialize(); fields seen earlier include:
#   name, password, nasName=GKDX, userIp, pid, vlan, sign, portalTemplateId, show_type maybe
PLAIN="name=${USERNAME}&password=${PASSWORD}&nasName=GKDX&userIp=${USERIP}&pid=${PID}&vlan=${VLAN}&sign=${SIGN}&portalTemplateId=${PORTAL}&show_type=0"

log "plaintext length: $(printf '%s' \"$PLAIN\" | wc -c) bytes"

# 4) Convert plaintext to hex, then zero-pad to 16-byte blocks (on hex level)
HEX_PLAIN=$(str2hex "$PLAIN")
# compute data length in bytes
BYTES_LEN=$(echo -n "$HEX_PLAIN" | wc -c)
# number of bytes = length / 2
DATLEN=$((BYTES_LEN / 2))
PAD_BYTES=$(( (16 - (DATLEN % 16)) % 16 ))

# Append PAD_BYTES of '00' to hex
PAD_HEX=""
i=0
while [ $i -lt $PAD_BYTES ]; do
  PAD_HEX="${PAD_HEX}00"
  i=$((i+1))
done
HEX_PLAIN_PAD="${HEX_PLAIN}${PAD_HEX}"

log "data bytes: $DATLEN, pad bytes: $PAD_BYTES, total hex len: $(printf '%s' \"$HEX_PLAIN_PAD\" | wc -c)"

# 5) Prepare key hex and iv hex
KEY_STR="1234567887654321"
KEY_HEX=$(str2hex "$KEY_STR")

# Important: frontend uses CryptoJS.enc.Utf8.parse(iv)
# That means iv is treated as the ASCII chars of the iv field.
# So we must convert the iv string bytes (ASCII) to hex (not decode hex)
IV_HEX=$(str2hex "$IV")
# If IV string bytes < 16 bytes, pad with 0x00 to 16 bytes (right pad)
IV_BYTES_LEN=$(( $(echo -n "$IV" | wc -c) ))
if [ $IV_BYTES_LEN -lt 16 ]; then
  PADN=$((16 - IV_BYTES_LEN))
  # append PADN bytes of 00 to IV_HEX
  j=0
  while [ $j -lt $PADN ]; do
    IV_HEX="${IV_HEX}00"
    j=$((j+1))
  done
fi

# 6) Convert hex plaintext to binary and encrypt with openssl (AES-128-CBC, nopad)
# We'll build binary by printf expansion of \xHH sequences
BIN_PLAIN="$(hex_to_bin_printf "$HEX_PLAIN_PAD")"

# Use openssl: key and iv in hex; -nopad because we already padded with zeros
ENC_BASE64=$(printf "%s" "$BIN_PLAIN" | openssl enc -aes-128-cbc -K "$KEY_HEX" -iv "$IV_HEX" -nopad -base64)

if [ -z "$ENC_BASE64" ]; then
  log "❌ openssl encryption failed or produced empty output"
  exit 1
fi

log "encrypted base64 len: $(printf '%s' \"$ENC_BASE64\" | wc -c)"

# 7) POST to authLogin (use --data-urlencode to preserve safe encoding)
AUTH_URL="http://${BASEURL}/gportal/web/authLogin?round=$((RANDOM%1000))"
log "POSTing to $AUTH_URL"

RESP=$(curl -s -A "$UA" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Origin: http://${BASEURL}" \
  -H "Referer: http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX" \
  --data-urlencode "data=${ENC_BASE64}" \
  --data-urlencode "iv=${IV}" \
  "$AUTH_URL")

# 8) Save and check response
echo "$RESP" > "$LAST_RESP"
log "server response: $RESP"

# try parse resultCode (simple)
RESULT=$(echo "$RESP" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
if [ "$RESULT" = "0" ]; then
  log "✅ 登录成功"
  exit 0
elif [ "$RESULT" = "2" ]; then
  log "⚠️ 检测到设备绑定冲突 (resultCode=2)，准备自动绑定..."

  # 提取被绑定的 MAC 地址
  BINDMAC=$(echo "$RESP" | sed -n 's/.*"bindmac":"\([^"]*\)".*/\1/p')
  log "原绑定设备 MAC: ${BINDMAC:-未知}"

  # 等待 5 秒再执行 rebind
  log "等待 5 秒后执行重新绑定..."
  sleep 5

  # 发起绑定请求（isRebind=true）
AUTH_URL_REBIND="http://${BASEURL}/gportal/web/authLogin?isRebind=true&round=$((RANDOM%1000))"
log "POSTing rebind to $AUTH_URL_REBIND"

RESP2=$(curl -s -A "$UA" \
  -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
  -H "Origin: http://${BASEURL}" \
  -H "Referer: http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX" \
  --data-urlencode "data=${ENC_BASE64}" \
  --data-urlencode "iv=${IV}" \
  "$AUTH_URL_REBIND")

echo "$RESP2" > "$LAST_RESP"
log "server response (after rebind): $RESP2"

RESULT2=$(echo "$RESP2" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

# 若 rebind 仍为 2，再试加 reBind=true 模式
if [ "$RESULT2" = "2" ]; then
  log "⚠️ 绑定请求仍返回 code=2，尝试使用 reBind=true 再试一次..."
  AUTH_URL_REBIND2="http://${BASEURL}/gportal/web/authLogin?isRebind=true&reBind=true&round=$((RANDOM%1000))"

  RESP2=$(curl -s -A "$UA" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: http://${BASEURL}" \
    -H "Referer: http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX" \
    --data-urlencode "data=${ENC_BASE64}&reBind=true" \
    --data-urlencode "iv=${IV}" \
    "$AUTH_URL_REBIND2")

  echo "$RESP2" > "$LAST_RESP"
  log "server response (after reBind=true): $RESP2"

  RESULT2=$(echo "$RESP2" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')
fi


  echo "$RESP2" > "$LAST_RESP"
  log "server response (after rebind): $RESP2"

  RESULT2=$(echo "$RESP2" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

  if [ "$RESULT2" = "0" ]; then
    log "✅ 已成功重新绑定设备"
  else
    log "⚠️ 绑定请求返回 code=$RESULT2，尝试继续登录..."
  fi

  # 绑定完成后再等待 5 秒（GiWiFi 系统内部延迟）
  log "等待 5 秒后重新发起登录..."
  sleep 5

  # 第三次：再执行正常登录请求
  AUTH_URL_FINAL="http://${BASEURL}/gportal/web/authLogin?round=$((RANDOM%1000))"
  log "POSTing final login to $AUTH_URL_FINAL"

  RESP3=$(curl -s -A "$UA" \
    -H "Content-Type: application/x-www-form-urlencoded; charset=UTF-8" \
    -H "Origin: http://${BASEURL}" \
    -H "Referer: http://${BASEURL}/gportal/web/login?wlanuserip=${USERIP}&wlanacname=GKDX" \
    --data-urlencode "data=${ENC_BASE64}" \
    --data-urlencode "iv=${IV}" \
    "$AUTH_URL_FINAL")

  echo "$RESP3" > "$LAST_RESP"
  log "server response (final login): $RESP3"

  RESULT3=$(echo "$RESP3" | sed -n 's/.*"resultCode"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')

  if [ "$RESULT3" = "0" ]; then
    log "✅ 自动绑定 + 登录全部完成"
    exit 0
  else
    log "❌ 最终登录失败 (resultCode: ${RESULT3:-<none>}). saved $LAST_RESP"
    exit 4
  fi
else
  log "❌ 登录失败 (resultCode: ${RESULT:-<none>}). saved $LAST_RESP"
  exit 2
fi
