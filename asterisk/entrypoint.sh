#!/bin/sh
set -e

# 1. Điền biến môi trường vào các file .tmpl.
#    Chỉ thay đúng các biến liệt kê dưới đây, để không đụng tới ${EXTEN}... trong dialplan.
VARS='${HOST_IP} ${DB_HOST} ${DB_PORT} ${DB_NAME} ${DB_USER} ${DB_PASSWORD} ${RTP_START} ${RTP_END}
      ${GATEWAY_IP} ${AMI_USER} ${AMI_SECRET} ${AMI_PERMIT_EXTRA} ${ARI_USER} ${ARI_PASSWORD_HASH}
      ${CONTAINER_IP}'
: "${GATEWAY_IP:=127.0.0.1}"
: "${AMI_PERMIT_EXTRA:=172.16.0.0/255.240.0.0}"
: "${AMI_USER:=gateway}"
: "${ARI_USER:=gateway}"
if [ -z "$AMI_SECRET" ] || [ -z "$ARI_PASSWORD" ]; then
  echo "LỖI: chưa đặt AMI_SECRET / ARI_PASSWORD trong .env" >&2; exit 1
fi
# ari.conf chỉ chứa mật khẩu đã băm (crypt SHA-512), không chứa mật khẩu gốc
ARI_PASSWORD_HASH=$(openssl passwd -6 "$ARI_PASSWORD")
# IP của container trong mạng Docker (đổi mỗi lần tạo lại container) -> rtp.conf đổi thành HOST_IP khi gửi ICE candidate
CONTAINER_IP=$(hostname -i | awk '{print $1}')
export GATEWAY_IP AMI_PERMIT_EXTRA AMI_USER ARI_USER ARI_PASSWORD_HASH CONTAINER_IP
for f in /opt/pbx-conf/*; do
  name=$(basename "$f")
  case "$name" in
    odbc.ini.tmpl) envsubst "$VARS" < "$f" > /etc/odbc.ini ;;
    *.tmpl)        envsubst "$VARS" < "$f" > "/etc/asterisk/${name%.tmpl}" ;;
    *)             cp "$f" "/etc/asterisk/$name" ;;
  esac
done

# 2. Chứng chỉ TLS cho WSS (cổng 8089). Chưa có thì tự tạo chứng chỉ tự ký (dùng cho lab).
#    Môi trường thật: chép chứng chỉ thật vào volume astkeys với đúng 2 tên file dưới đây.
KEYS=/etc/asterisk/keys
mkdir -p "$KEYS"
if [ ! -f "$KEYS/asterisk.crt" ] || [ ! -f "$KEYS/asterisk.key" ]; then
  echo "Tạo chứng chỉ tự ký cho ${HOST_IP}..."
  openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "$KEYS/asterisk.key" -out "$KEYS/asterisk.crt" \
    -subj "/CN=${HOST_IP}" -addext "subjectAltName=IP:${HOST_IP}" 2>/dev/null
fi
chown -R asterisk:asterisk "$KEYS" 2>/dev/null || true

# Múi giờ: Asterisk đọc /etc/localtime (không đọc biến TZ). Thiếu bước này thì cdr.calldate
# và tên file ghi âm theo giờ UTC (lệch 7 tiếng).
if [ -n "$TZ" ] && [ -f "/usr/share/zoneinfo/$TZ" ]; then
  ln -sf "/usr/share/zoneinfo/$TZ" /etc/localtime
  echo "$TZ" > /etc/timezone
fi

# Thư mục ghi âm cuộc gọi (volume recordings) - cũng là thư mục ghi âm của ARI
mkdir -p /var/spool/asterisk/recording
chown asterisk:asterisk /var/spool/asterisk/recording 2>/dev/null || true

# 3. Chờ PostgreSQL sẵn sàng
echo "Đang chờ database ${DB_HOST}:${DB_PORT}..."
until nc -z "$DB_HOST" "$DB_PORT"; do sleep 1; done

# 4. Chạy Asterisk ở foreground (log ra màn hình docker logs)
exec asterisk -f -vvv
