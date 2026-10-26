#!/usr/bin/env bash
# ============================================================
# Sao lưu cụm pbx-node (docs/sao-luu.md). Chạy TRÊN MÁY CHỦ, trong thư mục project, khi cụm đang chạy
# (không làm rớt cuộc gọi):
#   ./scripts/backup.sh [thư mục đích]        mặc định: BACKUP_DIR trong .env, không có thì ./backups
#
# Tạo <đích>/pbx-node-<YYYYmmdd-HHMMSS>/ gồm:
#   astdb.sqlite3    máy lẻ PJSIP (sqlite3 .backup: bản chụp nhất quán dù Asterisk đang ghi)
#   astconf.tar.gz   group (/etc/asterisk/gateway/queues-groups.conf)
#   astkeys.tar.gz   chứng chỉ TLS/WSS của Asterisk
#   astivr.tar.gz    lời chào IVR (menu IVR nằm trong astdb)
#   db.dump          PostgreSQL (pg_dump -Fc: bảng cdr = lịch sử cuộc gọi)
#   env              bản sao .env — CHỨA MẬT KHẨU (AMI/ARI/DB), quyền 600
#   MANIFEST         thời điểm, commit git, số máy lẻ / group / dòng cdr (để so khi khôi phục)
#   SHA256SUMS       kiểm tra file không hỏng
# Ghi âm (lớn) không nằm trong bản theo ngày: đặt BACKUP_RECORDINGS=yes -> rsync TĂNG DẦN vào <đích>/recordings/
# (chỉ chép file mới, không xóa file đã có trong bản sao lưu).
# Giữ BACKUP_KEEP_DAYS ngày (mặc định 14): xóa thư mục pbx-node-* cũ hơn. Mã thoát khác 0 = sao lưu lỗi.
#
# Biến (.env hoặc môi trường): BACKUP_DIR, BACKUP_KEEP_DAYS, BACKUP_RECORDINGS,
#   AST_CONTAINER (mặc định pbx-asterisk), DB_CONTAINER (mặc định pbx-db), DB_USER, DB_NAME.
# Chạy hằng ngày bằng cron: xem docs/sao-luu.md.
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

if [ -f .env ]; then set -a; . ./.env; set +a; fi
DEST="${1:-${BACKUP_DIR:-./backups}}"
KEEP="${BACKUP_KEEP_DAYS:-14}"
AST="${AST_CONTAINER:-pbx-asterisk}"
DBC="${DB_CONTAINER:-pbx-db}"
DB_USER="${DB_USER:-asterisk}"
DB_NAME="${DB_NAME:-asterisk}"
ASTDB=/var/lib/asterisk/astdb/astdb.sqlite3

log()  { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[$(date '+%F %T')] LỖI: $*" >&2; exit 1; }

[ -n "$DEST" ] && [ "$DEST" != "/" ] || fail "Thư mục đích không hợp lệ: '$DEST'"
for c in "$AST" "$DBC"; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null)" = "true" ] || fail "Container $c không chạy"
done

mkdir -p "$DEST"
NAME="pbx-node-$(date +%Y%m%d-%H%M%S)"
WORK="$DEST/.$NAME.partial"          # đổi tên thành $NAME khi xong; bản dở dang không bị nhầm là bản tốt
mkdir -p "$WORK"; chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT
log "Sao lưu vào $DEST/$NAME"

# 1. astdb (máy lẻ)
if docker exec "$AST" sh -c 'command -v sqlite3' >/dev/null 2>&1; then
  docker exec "$AST" sqlite3 "$ASTDB" ".backup /tmp/astdb-backup.sqlite3"
  CHECK=$(docker exec "$AST" sqlite3 /tmp/astdb-backup.sqlite3 "PRAGMA integrity_check;")
  [ "$CHECK" = "ok" ] || fail "astdb sao lưu không toàn vẹn: $CHECK"
  N_EXT=$(docker exec "$AST" sqlite3 /tmp/astdb-backup.sqlite3 "SELECT count(*) FROM astdb WHERE key LIKE '/pjsip/endpoint/%';")
  N_IVR=$(docker exec "$AST" sqlite3 /tmp/astdb-backup.sqlite3 "SELECT count(*) FROM astdb WHERE key LIKE '/ivr/%/default';")
  docker exec "$AST" cat /tmp/astdb-backup.sqlite3 > "$WORK/astdb.sqlite3"
  docker exec "$AST" rm -f /tmp/astdb-backup.sqlite3
else
  # Image cũ chưa có sqlite3 (cần: docker compose up -d --build). Chép thẳng file: thường dùng được nhưng có thể dính
  # ghi dở nếu đúng lúc đó có máy đăng ký/sửa máy lẻ.
  log "CẢNH BÁO: container chưa có sqlite3 -> chép thẳng file astdb (nên build lại image để sao lưu nhất quán)"
  docker exec "$AST" cat "$ASTDB" > "$WORK/astdb.sqlite3"
  N_EXT="?"; N_IVR="?"
fi
log "  astdb: $N_EXT máy lẻ, $N_IVR IVR"

# 2. Group + chứng chỉ
docker exec "$AST" tar -C /etc/asterisk/gateway -czf - . > "$WORK/astconf.tar.gz"
docker exec "$AST" tar -C /etc/asterisk/keys -czf - . > "$WORK/astkeys.tar.gz"
docker exec "$AST" tar -C /var/lib/asterisk/ivr -czf - . > "$WORK/astivr.tar.gz"   # lời chào IVR
N_GRP=$(docker exec "$AST" sh -c "grep -c '^\[' /etc/asterisk/gateway/queues-groups.conf 2>/dev/null || true")
log "  group: ${N_GRP:-0}"

# 3. PostgreSQL (lịch sử cuộc gọi)
docker exec "$DBC" pg_dump -U "$DB_USER" -d "$DB_NAME" -Fc > "$WORK/db.dump"
docker exec -i "$DBC" pg_restore -l < "$WORK/db.dump" > /dev/null || fail "db.dump không đọc được (pg_restore -l)"
N_CDR=$(docker exec "$DBC" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM cdr" 2>/dev/null || echo "?")
log "  db: $N_CDR dòng cdr"

# 4. .env (mật khẩu) + thông tin
if [ -f .env ]; then cp .env "$WORK/env"; chmod 600 "$WORK/env"; fi
{
  echo "time=$(date -Is)"
  echo "host=$(hostname)"
  echo "git=$(git rev-parse --short HEAD 2>/dev/null || echo '?')"
  echo "asterisk_image=$(docker inspect -f '{{.Config.Image}}' "$AST")"
  echo "extensions=$N_EXT"
  echo "groups=${N_GRP:-0}"
  echo "ivrs=$N_IVR"
  echo "cdr_rows=$N_CDR"
} > "$WORK/MANIFEST"
( cd "$WORK" && sha256sum astdb.sqlite3 astconf.tar.gz astkeys.tar.gz astivr.tar.gz db.dump > SHA256SUMS )

mv "$WORK" "$DEST/$NAME"
trap - EXIT
log "Xong: $DEST/$NAME ($(du -sh "$DEST/$NAME" | cut -f1))"

# 5. Ghi âm (tùy chọn, tăng dần)
if [ "${BACKUP_RECORDINGS:-no}" = "yes" ]; then
  SRC=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/spool/asterisk/recording"}}{{.Source}}{{end}}{{end}}' "$AST")
  if ! command -v rsync >/dev/null; then
    log "CẢNH BÁO: chưa có rsync (sudo apt install rsync) -> bỏ qua ghi âm"
  elif [ -z "$SRC" ] || [ ! -r "$SRC" ]; then
    log "CẢNH BÁO: không đọc được thư mục ghi âm '$SRC' (volume Docker cần chạy script bằng root) -> bỏ qua ghi âm"
  else
    mkdir -p "$DEST/recordings"
    rsync -a "$SRC/" "$DEST/recordings/"
    log "  ghi âm: đã đồng bộ vào $DEST/recordings ($(du -sh "$DEST/recordings" | cut -f1))"
  fi
fi

# 6. Xóa bản cũ (chỉ thư mục pbx-node-* trong $DEST)
find "$DEST" -mindepth 1 -maxdepth 1 -type d -name 'pbx-node-*' -mtime +"$KEEP" -print -exec rm -rf {} + \
  | sed 's/^/[xóa bản cũ] /'
