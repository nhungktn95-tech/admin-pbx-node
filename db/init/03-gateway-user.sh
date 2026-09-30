#!/bin/sh
# ============================================================
# Tạo user DB riêng cho PBX Gateway, chỉ đủ quyền cần thiết:
#   - đọc/ghi máy lẻ (ps_*) và group (queues, queue_members)
#   - chỉ ĐỌC lịch sử cuộc gọi (cdr)
# Chạy tự động ở lần khởi động DB đầu tiên.
# Với DB đã có dữ liệu, chạy tay:
#   docker compose exec db sh /docker-entrypoint-initdb.d/03-gateway-user.sh
# ============================================================
set -e
: "${GW_DB_USER:?Chưa đặt GW_DB_USER trong .env}"
: "${GW_DB_PASSWORD:?Chưa đặt GW_DB_PASSWORD trong .env}"

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v gw_user="$GW_DB_USER" -v gw_pass="$GW_DB_PASSWORD" -v db_name="$POSTGRES_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'gw_user', :'gw_pass')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'gw_user') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'gw_user', :'gw_pass') \gexec

GRANT CONNECT ON DATABASE :"db_name" TO :"gw_user";
GRANT USAGE ON SCHEMA public TO :"gw_user";
GRANT SELECT, INSERT, UPDATE, DELETE ON ps_endpoints, ps_auths, ps_aors, queues, queue_members TO :"gw_user";
GRANT USAGE, SELECT ON SEQUENCE queue_members_uniqueid_seq TO :"gw_user";
GRANT SELECT ON cdr TO :"gw_user";
SQL
echo "Đã tạo/cập nhật user DB cho Gateway: $GW_DB_USER"
