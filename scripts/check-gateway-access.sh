#!/usr/bin/env bash
# ============================================================
# Chạy TRÊN MÁY GATEWAY để kiểm tra đã vào được cụm pbx-node chưa.
#   ./scripts/check-gateway-access.sh <HOST_IP> [đường dẫn .env]
# Cần: nc (netcat), curl. Gateway chỉ dùng AMI + ARI, không dùng DB của cụm (từ Bước G2).
# ============================================================
set -u
HOST="${1:?Cách dùng: $0 <HOST_IP> [.env]}"
ENV_FILE="${2:-.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
ok()   { printf "  \033[32mOK\033[0m   %s\n" "$1"; }
fail() { printf "  \033[31mLỖI\033[0m  %s\n" "$1"; FAILED=1; }
FAILED=0

echo "1) Cổng mạng"
for p in 5038 8088 8089; do nc -z -w 3 "$HOST" $p 2>/dev/null && ok "tcp/$p mở" || fail "tcp/$p không vào được (firewall? ADMIN_BIND?)"; done

echo "2) AMI đăng nhập bằng $AMI_USER"
AMI_OUT=$(printf "Action: Login\r\nUsername: %s\r\nSecret: %s\r\n\r\nAction: CoreSettings\r\n\r\nAction: Logoff\r\n\r\n" \
  "$AMI_USER" "$AMI_SECRET" | nc -w 3 "$HOST" 5038 2>/dev/null | tr -d '\r')
if echo "$AMI_OUT" | grep -q "Authentication accepted"; then
  ok "đăng nhập AMI, Asterisk $(echo "$AMI_OUT" | sed -n 's/^AsteriskVersion: //p')"
else
  fail "AMI từ chối (sai AMI_SECRET hoặc IP chưa nằm trong permit của manager.conf)"
fi

echo "3) ARI"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$ARI_USER:$ARI_PASSWORD" "http://$HOST:8088/ari/asterisk/info")
[ "$CODE" = "200" ] && ok "ARI trả 200" || fail "ARI trả $CODE"
# Máy lẻ lưu trong astdb, Gateway ghi qua ARI Push Configuration: thử tạo rồi xóa một aor tạm
AOR="http://$HOST:8088/ari/asterisk/config/dynamic/res_pjsip/aor/__gw_test"
CODE=$(curl -s -o /dev/null -w "%{http_code}" -u "$ARI_USER:$ARI_PASSWORD" -X PUT -H 'Content-Type: application/json' \
  -d '{"fields":[{"attribute":"max_contacts","value":"1"}]}' "$AOR")
curl -s -o /dev/null -u "$ARI_USER:$ARI_PASSWORD" -X DELETE "$AOR"
[ "$CODE" = "200" ] && ok "ARI ghi được máy lẻ (tạo + xóa aor tạm)" \
  || fail "ARI không ghi được máy lẻ ($CODE) — sorcery.conf đã là astdb chưa? user ARI có read_only không?"

echo "4) WSS cho Softphone SDK"
CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://$HOST:8089/ws")
# Không gửi header nâng cấp WebSocket nên Asterisk trả 400/426 = cổng WSS đang chạy
case "$CODE" in 400|426) ok "https://$HOST:8089/ws trả $CODE (WSS sẵn sàng)";; *) fail "WSS trả $CODE";; esac

echo
[ $FAILED = 0 ] && echo "=> Bước 1 xong: Gateway kết nối được." || { echo "=> Còn lỗi, xem các dòng LỖI ở trên."; exit 1; }
