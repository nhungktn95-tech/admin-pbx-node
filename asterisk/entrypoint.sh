#!/bin/sh
set -e

# 1. Điền biến môi trường vào các file .tmpl.
#    Chỉ thay đúng các biến liệt kê dưới đây, để không đụng tới ${EXTEN}... trong dialplan.
VARS='${HOST_IP} ${DB_HOST} ${DB_PORT} ${DB_NAME} ${DB_USER} ${DB_PASSWORD} ${RTP_START} ${RTP_END}
      ${GATEWAY_IP} ${AMI_USER} ${AMI_SECRET} ${AMI_PERMIT_EXTRA} ${ARI_USER} ${ARI_PASSWORD_HASH}
      ${CONTAINER_IP} ${AST_ADMIN_BIND} ${AST_WSS_BIND}'
: "${GATEWAY_IP:=127.0.0.1}"
# Địa chỉ nghe của AMI/ARI và WSS. Lab/Docker bridge: 0.0.0.0. docker-compose.cloud.yml đặt IP nội bộ / 127.0.0.1.
: "${AST_ADMIN_BIND:=0.0.0.0}"
: "${AST_WSS_BIND:=0.0.0.0}"
: "${AMI_PERMIT_EXTRA:=172.16.0.0/255.240.0.0}"
: "${AMI_USER:=gateway}"
: "${ARI_USER:=gateway}"
if [ -z "$AMI_SECRET" ] || [ -z "$ARI_PASSWORD" ]; then
  echo "LỖI: chưa đặt AMI_SECRET / ARI_PASSWORD trong .env" >&2; exit 1
fi
# ari.conf chỉ chứa mật khẩu đã băm (crypt SHA-512), không chứa mật khẩu gốc
ARI_PASSWORD_HASH=$(openssl passwd -6 "$ARI_PASSWORD")
# IP của chính Asterisk (dùng cho local_net và ICE candidate -> HOST_IP).
#   Docker bridge: IP container (đổi mỗi lần tạo lại container), lấy bằng hostname -i.
#   network_mode host (cloud): đặt LOCAL_IP = IP card mạng của máy chủ; hostname -i ở chế độ này hay trả 127.0.1.1.
CONTAINER_IP=${LOCAL_IP:-$(hostname -i | awk '{print $1}')}
export GATEWAY_IP AMI_PERMIT_EXTRA AMI_USER ARI_USER ARI_PASSWORD_HASH CONTAINER_IP AST_ADMIN_BIND AST_WSS_BIND
for f in /opt/pbx-conf/*; do
  name=$(basename "$f")
  case "$name" in
    odbc.ini.tmpl) envsubst "$VARS" < "$f" > /etc/odbc.ini ;;
    *.tmpl)        envsubst "$VARS" < "$f" > "/etc/asterisk/${name%.tmpl}" ;;
    queues-groups.conf) ;;   # group: bản mẫu, chép vào volume astconf bên dưới
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

# Máy lẻ PJSIP lưu trong astdb (sorcery.conf). Để astdb ở thư mục riêng (volume astdb) thay vì cả /var/lib/asterisk,
# để moh/sounds trong image vẫn được cập nhật khi build lại.
mkdir -p /var/lib/asterisk/astdb
chown asterisk:asterisk /var/lib/asterisk/astdb 2>/dev/null || true
# asterisk.conf của gói Ubuntu để [directories](!) — dấu (!) là template nên Asterisk bỏ qua cả mục; bỏ (!) để mục có
# hiệu lực (các đường dẫn khác trong mục vốn trùng mặc định của gói). File astdb = <astdbdir>/astdb.sqlite3.
sed -i -e 's|^\[directories\](!)|[directories]|' -e 's|^astdbdir *=>.*|astdbdir => /var/lib/asterisk/astdb|' /etc/asterisk/asterisk.conf

# Group (queue): Gateway sửa /etc/asterisk/gateway/queues-groups.conf qua AMI UpdateConfig (queues.conf #include file này).
# Thư mục gateway/ là volume astconf nên không bị chép đè mỗi lần khởi động; chỉ chép bản mẫu khi volume còn trống.
mkdir -p /etc/asterisk/gateway
[ -f /etc/asterisk/gateway/queues-groups.conf ] || cp /opt/pbx-conf/queues-groups.conf /etc/asterisk/gateway/queues-groups.conf
chown -R asterisk:asterisk /etc/asterisk/gateway 2>/dev/null || true

# Log sự kiện bảo mật (sai mật khẩu, máy lẻ không tồn tại...) ra /var/log/asterisk/security.log (volume astlogs)
# để fail2ban đọc và chặn IP dò mật khẩu (docker-compose.cloud.yml). logger.conf của gói Ubuntu không bật mục này.
grep -q '^security.log' /etc/asterisk/logger.conf || sed -i '/^\[logfiles\]/a security.log => security' /etc/asterisk/logger.conf
# Khi xoay vòng log ("logger rotate", chạy mỗi ngày ở bước 5): đổi tên file cũ thành <tên>.<thời điểm>, mở file mới.
grep -q '^rotatestrategy' /etc/asterisk/logger.conf || sed -i '/^\[general\]/a rotatestrategy = timestamp' /etc/asterisk/logger.conf

# Thư mục ghi âm cuộc gọi (volume recordings) - cũng là thư mục ghi âm của ARI
mkdir -p /var/spool/asterisk/recording
chown asterisk:asterisk /var/spool/asterisk/recording 2>/dev/null || true

# 3. Chờ PostgreSQL sẵn sàng
echo "Đang chờ database ${DB_HOST}:${DB_PORT}..."
until nc -z "$DB_HOST" "$DB_PORT"; do sleep 1; done

# 4. Thông tin sức chứa + kiểm tra giới hạn file mở (ulimit). Xem docs/chiu-tai.md.
RTP_PORTS=$((RTP_END - RTP_START + 1))
echo "Dải RTP ${RTP_START}-${RTP_END}: ${RTP_PORTS} cổng ≈ $((RTP_PORTS / 2)) kênh ≈ $((RTP_PORTS / 4)) cuộc gọi 2 bên cùng lúc" \
     "(gọi group ringall: mỗi thành viên đang đổ chuông cũng chiếm 1 kênh)"
NOFILE=$(ulimit -n)
if [ "$NOFILE" != "unlimited" ] && [ "$NOFILE" -lt 65536 ]; then
  echo "CẢNH BÁO: giới hạn file mở (ulimit -n) chỉ $NOFILE — tải cao sẽ lỗi 'Too many open files'." \
       "Kiểm tra mục ulimits của asterisk trong docker-compose.yml." >&2
fi

# 5. Dọn dẹp định kỳ, chạy nền mỗi giờ (tiến trình con của Asterisk, dừng cùng container):
#    - Mỗi ngày một lần: xoay vòng log Asterisk, xóa log cũ hơn LOG_KEEP_DAYS ngày (mặc định 14).
#    - Cảnh báo ra docker logs khi ổ chứa ghi âm / log / astdb dùng >= DISK_WARN_PERCENT % (mặc định 85).
#    - Chỉ khi đặt RECORDING_KEEP_DAYS: xóa file ghi âm cũ hơn số ngày đó. Mặc định KHÔNG xóa (quyết định "không tự
#      xóa file ghi âm" vẫn giữ). Lưu ý: cdr.recordingfile vẫn còn tên file đã xóa -> Gateway tải sẽ nhận 404.
LOG_KEEP_DAYS=${LOG_KEEP_DAYS:-14}
DISK_WARN_PERCENT=${DISK_WARN_PERCENT:-85}
RECORDING_KEEP_DAYS=${RECORDING_KEEP_DAYS:-}
check_disk() {
  df -P /var/spool/asterisk/recording /var/log/asterisk /var/lib/asterisk/astdb 2>/dev/null | awk -v t="$DISK_WARN_PERCENT" '
    NR > 1 { u = $5; sub("%", "", u)
             if (u + 0 >= t && !seen[$1]++) printf "[don-dep] CẢNH BÁO: ổ chứa %s đã dùng %s%% (ngưỡng %s%%)\n", $6, u, t }' >&2
}
housekeeping() {
  last_rotate=$(date +%Y%m%d)
  while sleep 3600; do
    today=$(date +%Y%m%d)
    if [ "$today" != "$last_rotate" ]; then
      asterisk -rx "logger rotate" >/dev/null 2>&1 && last_rotate=$today
      # Sau khi xoay vòng, file đang ghi đều mới tạo -> chỉ file đã xoay vòng mới đủ cũ để bị xóa. queue_log giữ nguyên.
      find /var/log/asterisk -maxdepth 1 -type f ! -name queue_log -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null
    fi
    if [ -n "$RECORDING_KEEP_DAYS" ]; then
      find /var/spool/asterisk/recording -type f -name '*.wav' -mtime +"$RECORDING_KEEP_DAYS" -delete 2>/dev/null
    fi
    check_disk
  done
}
check_disk
housekeeping &

# 6. Chạy Asterisk ở foreground (log ra màn hình docker logs).
#    AST_VERBOSE = mức chi tiết của log màn hình (mặc định 3 = in từng bước dialplan, tiện gỡ lỗi ở lab).
#    Tải cao / môi trường thật nên đặt 0 hoặc 1: mức 3 sinh hàng chục dòng log cho mỗi cuộc gọi.
VFLAGS=""
i=0
while [ "$i" -lt "${AST_VERBOSE:-3}" ]; do VFLAGS="${VFLAGS}v"; i=$((i + 1)); done
exec asterisk -f ${VFLAGS:+-$VFLAGS}
