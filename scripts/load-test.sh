#!/usr/bin/env bash
# ============================================================
# Thử tải cụm pbx-node bằng SIPp (docs/chiu-tai.md).
#   ./scripts/load-test.sh <HOST_IP> <số cuộc đồng thời> [giây mỗi cuộc=60] [cuộc mới/giây=5] [.env]
# Ví dụ: tăng dần  ./scripts/load-test.sh 10.0.1.5 50   rồi 100, 200... tới khi bắt đầu có cuộc lỗi / mất tiếng.
#
# Chạy trên một máy Linux KHÁC máy tổng đài (cùng mạng nội bộ/VPC) để SIPp không tranh CPU với Asterisk.
# Cần: sipp (Ubuntu: sudo apt install sip-tester), curl, md5sum. Máy chạy phải vào được ARI (ARI_HOST:8088).
#
# Script làm gì:
#   1. Tạo máy lẻ thử LOADTEST_EXT (mặc định 599) qua ARI, mật khẩu ngẫu nhiên.
#   2. SIPp gọi *45 (dialplan: nhấc máy, ghi âm, phát nhạc chờ), SIPp phát lại âm thanh -> RTP 2 chiều.
#      Mỗi cuộc thử = 1 kênh Asterisk ≈ một nửa cuộc gọi thật 2 bên.
#   3. Hết giờ (hoặc Ctrl+C) thì xóa máy lẻ thử.
# Trong lúc chạy, trên máy tổng đài theo dõi:
#   docker compose exec asterisk asterisk -rx "core show channels count"
#   docker stats pbx-asterisk           (CPU, RAM)
#   docker compose exec asterisk asterisk -rx "pjsip show channelstats"   (mất gói, jitter)
# ============================================================
set -u
HOST="${1:?Cách dùng: $0 <HOST_IP> <số cuộc đồng thời> [giây mỗi cuộc] [cuộc mới/giây] [.env]}"
CALLS="${2:?Thiếu số cuộc đồng thời}"
DURATION="${3:-60}"
RATE="${4:-5}"
ENV_FILE="${5:-.env}"
# shellcheck disable=SC1090
[ -f "$ENV_FILE" ] && set -a && . "$ENV_FILE" && set +a
: "${ARI_USER:?Thiếu ARI_USER (.env)}" "${ARI_PASSWORD:?Thiếu ARI_PASSWORD (.env)}"
# Cloud: ARI chỉ nghe IP nội bộ (ADMIN_BIND), SIP nghe IP public -> đặt ARI_HOST riêng nếu khác HOST_IP.
ARI_HOST="${ARI_HOST:-$HOST}"
EXT="${LOADTEST_EXT:-599}"
SCEN="$(cd "$(dirname "$0")" && pwd)/load-test/uac-auth.xml"
command -v sipp >/dev/null || { echo "Chưa có sipp. Ubuntu/Debian: sudo apt install sip-tester" >&2; exit 1; }

ARI="http://$ARI_HOST:8088/ari/asterisk/config/dynamic/res_pjsip"
ari() { curl -s -o /dev/null -w "%{http_code}" -u "$ARI_USER:$ARI_PASSWORD" "$@"; }

# Không ghi đè máy lẻ thật
CODE=$(ari "$ARI/endpoint/$EXT")
if [ "$CODE" = "200" ]; then
  echo "Máy lẻ $EXT đã tồn tại. Đặt LOADTEST_EXT=<số trống trong 100-599> rồi chạy lại." >&2; exit 1
elif [ "$CODE" != "404" ]; then
  echo "ARI trả $CODE tại $ARI_HOST:8088 (sai ARI_HOST/mật khẩu, hay firewall?)" >&2; exit 1
fi

PASS=$(head -c 12 /dev/urandom | md5sum | cut -c1-16)
MD5=$(printf '%s' "$EXT:asterisk:$PASS" | md5sum | cut -c1-32)
cleanup() {
  ari -X DELETE "$ARI/endpoint/$EXT" >/dev/null
  ari -X DELETE "$ARI/auth/$EXT" >/dev/null
  echo "Đã xóa máy lẻ thử $EXT."
}
trap cleanup EXIT
trap 'exit 130' INT TERM

CODE=$(ari -X PUT -H 'Content-Type: application/json' "$ARI/auth/$EXT" \
  -d "{\"fields\":[{\"attribute\":\"auth_type\",\"value\":\"md5\"},{\"attribute\":\"username\",\"value\":\"$EXT\"},
       {\"attribute\":\"realm\",\"value\":\"asterisk\"},{\"attribute\":\"md5_cred\",\"value\":\"$MD5\"}]}")
[ "$CODE" = "200" ] || { echo "Tạo auth $EXT lỗi ($CODE)" >&2; exit 1; }
CODE=$(ari -X PUT -H 'Content-Type: application/json' "$ARI/endpoint/$EXT" \
  -d "{\"fields\":[{\"attribute\":\"auth\",\"value\":\"$EXT\"},{\"attribute\":\"context\",\"value\":\"from-internal\"},
       {\"attribute\":\"disallow\",\"value\":\"all\"},{\"attribute\":\"allow\",\"value\":\"ulaw\"},
       {\"attribute\":\"direct_media\",\"value\":\"no\"},{\"attribute\":\"rtp_symmetric\",\"value\":\"yes\"},
       {\"attribute\":\"force_rport\",\"value\":\"yes\"},{\"attribute\":\"rewrite_contact\",\"value\":\"yes\"},
       {\"attribute\":\"dtmf_mode\",\"value\":\"rfc4733\"},{\"attribute\":\"callerid\",\"value\":\"Thu tai <$EXT>\"}]}")
[ "$CODE" = "200" ] || { echo "Tạo endpoint $EXT lỗi ($CODE)" >&2; exit 1; }

TOTAL=$((CALLS * 2))   # đủ để giữ mức CALLS cuộc đồng thời trong khoảng một lượt thời lượng
echo "Thử tải $HOST: tối đa $CALLS cuộc đồng thời, mỗi cuộc ${DURATION}s, $RATE cuộc mới/giây, tổng $TOTAL cuộc."
echo "Cần dải RTP >= $((CALLS * 2)) cổng trên tổng đài (mỗi cuộc thử 1 kênh = 2 cổng)."
sipp "$HOST:5060" -sf "$SCEN" -s '*45' -set user "$EXT" -au "$EXT" -ap "$PASS" \
  -l "$CALLS" -r "$RATE" -m "$TOTAL" -d $((DURATION * 1000)) -rtp_echo -nostdin \
  -trace_stat -stf "loadtest-$(date +%Y%m%d-%H%M%S).csv" -fd 5 ${SIPP_EXTRA:-}
RC=$?
echo
[ $RC = 0 ] && echo "=> Mọi cuộc thử thành công." || echo "=> Có cuộc lỗi (mã $RC). Xem cột FailedCall* trong file loadtest-*.csv và log Asterisk."
exit $RC
