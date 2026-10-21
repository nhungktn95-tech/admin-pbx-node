#!/bin/sh
# ============================================================
# Chuyển máy lẻ cũ từ Realtime DB (ps_aors, ps_auths, ps_endpoints) sang astdb qua ARI.
# Dùng MỘT lần cho cụm đã có máy lẻ từ trước khi đổi sorcery.conf sang astdb.
#
#   1. git pull (bản có sorcery.conf = astdb)
#   2. docker compose up -d --build        (từ lúc này Asterisk chỉ thấy máy lẻ trong astdb → máy cũ tạm mất)
#   3. sh scripts/chuyen-may-le-sang-astdb.sh   (ngay sau bước 2)
#
# Giữ nguyên md5_cred → mật khẩu SIP không đổi, softphone không phải đăng nhập lại.
# Không xóa dữ liệu ps_* (giữ làm bản lưu). Chạy lại được: máy đã có trong astdb thì ghi đè cùng giá trị.
#
# Biến tùy chọn:
#   ENV_FILE  file .env (mặc định ./.env)
#   COMPOSE   lệnh docker compose (mặc định "docker compose")
#   ARI_URL   mặc định http://<ADMIN_BIND hoặc 127.0.0.1>:8088/ari
# ============================================================
set -eu

ENV_FILE=${ENV_FILE:-./.env}
COMPOSE=${COMPOSE:-docker compose}
[ -f "$ENV_FILE" ] || { echo "Không thấy $ENV_FILE" >&2; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${ARI_USER:?Thiếu ARI_USER trong .env}"
: "${ARI_PASSWORD:?Thiếu ARI_PASSWORD trong .env}"

HOST=${ADMIN_BIND:-127.0.0.1}
[ "$HOST" = "0.0.0.0" ] && HOST=127.0.0.1
ARI_URL=${ARI_URL:-http://$HOST:8088/ari}
BASE="$ARI_URL/asterisk/config/dynamic/res_pjsip"

curl -sf -o /dev/null -u "$ARI_USER:$ARI_PASSWORD" "$ARI_URL/asterisk/info" \
  || { echo "Không gọi được ARI $ARI_URL (Asterisk đã chạy chưa? ARI_USER/ARI_PASSWORD đúng chưa?)" >&2; exit 1; }

# Mỗi dòng: <id>\t{"fields":[...]} — chỉ các cột có giá trị; "disallow" phải đứng trước "allow".
# ps_auths bỏ cột password (luôn NULL).
rows() {
  $COMPOSE exec -T db psql -U "$DB_USER" -d "$DB_NAME" -At -F "$(printf '\t')" -c "
    SELECT t.id, json_build_object('fields', coalesce(json_agg(json_build_object('attribute', f.key, 'value', f.value)
               ORDER BY (f.key <> 'disallow'), f.key) FILTER (WHERE f.value IS NOT NULL AND f.value <> ''), '[]'))
    FROM $1 t, jsonb_each_text(to_jsonb(t) - 'id' - 'password') f
    GROUP BY t.id ORDER BY t.id"
}

ok=0; fail=0
for obj in aor:ps_aors auth:ps_auths endpoint:ps_endpoints; do
  type=${obj%%:*}; table=${obj#*:}
  rows "$table" > /tmp/pbx-migrate.$$ || { echo "Không đọc được bảng $table" >&2; exit 1; }
  while IFS="$(printf '\t')" read -r id body; do
    [ -n "$id" ] || continue
    code=$(curl -s -o /tmp/pbx-migrate-res.$$ -w '%{http_code}' -u "$ARI_USER:$ARI_PASSWORD" \
      -H 'Content-Type: application/json' -X PUT "$BASE/$type/$id" -d "$body")
    if [ "$code" = 200 ]; then
      ok=$((ok + 1)); echo "  $type $id: OK"
    else
      fail=$((fail + 1)); echo "  $type $id: LỖI $code $(head -c 200 /tmp/pbx-migrate-res.$$)" >&2
    fi
  done < /tmp/pbx-migrate.$$
done
rm -f /tmp/pbx-migrate.$$ /tmp/pbx-migrate-res.$$

echo "Xong: $ok đối tượng OK, $fail lỗi."
echo "Kiểm tra: $COMPOSE exec asterisk asterisk -rx 'pjsip show endpoints'"
[ "$fail" = 0 ]
