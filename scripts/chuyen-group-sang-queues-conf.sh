#!/bin/sh
# ============================================================
# Chuyển group cũ từ Realtime DB (bảng queues, queue_members) sang /etc/asterisk/gateway/queues-groups.conf
# (volume astconf). Dùng MỘT lần cho cụm đã có group trước Bước G3, ngay sau `docker compose up -d --build`.
# Thứ tự member = thứ tự uniqueid trong queue_members (thứ tự thêm vào). Ghi đè file group trong volume.
#
# Biến tùy chọn: ENV_FILE (mặc định ./.env), COMPOSE (mặc định "docker compose")
# ============================================================
set -eu

ENV_FILE=${ENV_FILE:-./.env}
COMPOSE=${COMPOSE:-docker compose}
[ -f "$ENV_FILE" ] || { echo "Không thấy $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a

CONF=$($COMPOSE exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -c "
  SELECT string_agg(block, E'\n' ORDER BY name) FROM (
    SELECT q.name, '[' || q.name || ']' || E'\n'
      || 'strategy = ' || coalesce(q.strategy, 'ringall') || E'\n'
      || 'timeout = ' || coalesce(q.timeout, 20) || E'\n'
      || 'retry = ' || coalesce(q.retry, 2) || E'\n'
      || 'wrapuptime = ' || coalesce(q.wrapuptime, 0) || E'\n'
      || 'ringinuse = no' || E'\n'
      || 'joinempty = ' || coalesce(q.joinempty, 'yes') || E'\n'
      || 'leavewhenempty = ' || coalesce(q.leavewhenempty, 'no') || E'\n'
      || coalesce((SELECT string_agg('member => ' || m.interface || ',' || coalesce(m.penalty, 0) || ','
                                     || coalesce(m.membername, m.interface) || ',' || coalesce(m.state_interface, m.interface),
                                     E'\n' ORDER BY m.uniqueid) || E'\n'
                   FROM queue_members m WHERE m.queue_name = q.name), '') AS block
    FROM queues q) t")
[ -n "$CONF" ] || { echo "Bảng queues trống, không có gì để chuyển."; exit 0; }

printf '; Group chuyển từ bảng queues/queue_members (%s). Từ đây PBX Gateway quản lý qua AMI UpdateConfig.\n\n%s\n' \
  "$(date '+%Y-%m-%d %H:%M')" "$CONF" \
  | $COMPOSE exec -T asterisk sh -c 'cat > /etc/asterisk/gateway/queues-groups.conf'
$COMPOSE exec -T asterisk asterisk -rx "queue reload all" >/dev/null
echo "Đã chuyển. Kiểm tra: $COMPOSE exec asterisk asterisk -rx 'queue show'"
