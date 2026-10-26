#!/bin/sh
# ============================================================
# User DB cho cdr-shipper (giao lịch sử cuộc gọi sang PBX Gateway, docs/cdr-shipper.md): CHỈ ĐỌC bảng cdr.
# User này chỉ dùng TRONG cụm (container cdr-shipper), không đưa cho bên nào khác.
# Chạy tự động ở lần khởi động DB đầu tiên (bỏ qua nếu chưa đặt CDR_SHIPPER_DB_PASSWORD).
# DB đã có dữ liệu, hoặc vừa đổi mật khẩu, chạy tay:
#   docker compose exec db sh /docker-entrypoint-initdb.d/04-cdr-shipper-user.sh
# ============================================================
set -e
if [ -z "$CDR_SHIPPER_DB_PASSWORD" ]; then
  echo "Bỏ qua tạo user cdr-shipper (chưa đặt CDR_SHIPPER_DB_PASSWORD)"; exit 0
fi
: "${CDR_SHIPPER_DB_USER:=cdr_shipper}"

psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
     -v su="$CDR_SHIPPER_DB_USER" -v sp="$CDR_SHIPPER_DB_PASSWORD" -v db_name="$POSTGRES_DB" <<'SQL'
SELECT format('CREATE ROLE %I LOGIN PASSWORD %L', :'su', :'sp')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'su') \gexec
SELECT format('ALTER ROLE %I LOGIN PASSWORD %L', :'su', :'sp') \gexec

GRANT CONNECT ON DATABASE :"db_name" TO :"su";
GRANT USAGE ON SCHEMA public TO :"su";
GRANT SELECT ON cdr TO :"su";
SQL
echo "Đã tạo/cập nhật user DB cho cdr-shipper: $CDR_SHIPPER_DB_USER (chỉ SELECT cdr)"
