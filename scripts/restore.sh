#!/usr/bin/env bash
# ============================================================
# Khôi phục cụm pbx-node từ một bản sao lưu của scripts/backup.sh (docs/sao-luu.md).
# Chạy TRÊN MÁY CHỦ, trong thư mục project, khi container db + asterisk đã được tạo (docker compose up -d):
#   ./scripts/restore.sh <thư mục bản sao lưu> [--yes] [--parts astdb,astconf,astkeys,astivr,db]
#
# Làm gì (GHI ĐÈ dữ liệu hiện tại):
#   0. Kiểm tra SHA256SUMS; hỏi xác nhận (bỏ qua bằng --yes)
#   1. Sao lưu trạng thái HIỆN TẠI trước (scripts/backup.sh -> <thư mục cha>/pre-restore) để quay lại được
#   2. Dừng Asterisk (cuộc gọi đang diễn ra bị ngắt)
#   3. Ghi đè các phần được chọn (mặc định tất cả): astdb (máy lẻ + menu IVR), astconf (group), astkeys (chứng chỉ),
#      astivr (lời chào IVR), db (cdr). Phần không có trong bản sao lưu (bản cũ) thì bỏ qua.
#   4. Khởi động lại Asterisk, in số máy lẻ / group / dòng cdr để so với MANIFEST của bản sao lưu
# KHÔNG tự khôi phục: .env (so sánh tay với file "env" trong bản sao lưu) và ghi âm (rsync tay, xem docs/sao-luu.md).
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:?Cách dùng: $0 <thư mục bản sao lưu> [--yes] [--parts astdb,astconf,astkeys,astivr,db]}"
shift
YES=no; PARTS="astdb,astconf,astkeys,astivr,db"
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=yes ;;
    --parts) PARTS="${2:?Thiếu danh sách sau --parts}"; shift ;;
    *) echo "Tham số lạ: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -f .env ]; then set -a; . ./.env; set +a; fi
AST="${AST_CONTAINER:-pbx-asterisk}"
DBC="${DB_CONTAINER:-pbx-db}"
DB_USER="${DB_USER:-asterisk}"
DB_NAME="${DB_NAME:-asterisk}"
has() { case ",$PARTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
log()  { echo "[$(date '+%F %T')] $*"; }
fail() { echo "[$(date '+%F %T')] LỖI: $*" >&2; exit 1; }

SRC="$(cd "$SRC" && pwd)" || fail "Không thấy thư mục $1"
[ -f "$SRC/SHA256SUMS" ] || fail "$SRC không phải bản sao lưu (thiếu SHA256SUMS)"
( cd "$SRC" && sha256sum -c --quiet SHA256SUMS ) || fail "File sao lưu bị hỏng (SHA256SUMS không khớp)"
docker inspect "$AST" >/dev/null 2>&1 || fail "Chưa có container $AST (chạy docker compose up -d trước)"
[ "$(docker inspect -f '{{.State.Running}}' "$DBC" 2>/dev/null)" = "true" ] || fail "Container $DBC không chạy"
IMAGE=$(docker inspect -f '{{.Config.Image}}' "$AST")

echo "Bản sao lưu: $SRC"; sed 's/^/   /' "$SRC/MANIFEST"
echo "Sẽ GHI ĐÈ: $PARTS  — Asterisk sẽ dừng trong lúc khôi phục (ngắt mọi cuộc gọi)."
if [ "$YES" != yes ]; then
  read -r -p "Gõ KHOI PHUC để tiếp tục: " ans
  [ "$ans" = "KHOI PHUC" ] || { echo "Đã hủy."; exit 1; }
fi

# 1. Lưu trạng thái hiện tại để quay lại được (cần Asterisk đang chạy)
if [ "$(docker inspect -f '{{.State.Running}}' "$AST")" = "true" ]; then
  log "Sao lưu trạng thái hiện tại trước khi ghi đè..."
  BACKUP_RECORDINGS=no BACKUP_KEEP_DAYS=36500 ./scripts/backup.sh "$(dirname "$SRC")/pre-restore"
else
  log "CẢNH BÁO: $AST đang dừng -> không sao lưu được trạng thái hiện tại trước khi ghi đè"
fi

# 2. Dừng Asterisk. Từ đây, dù bước nào lỗi cũng PHẢI khởi động lại Asterisk (không để tổng đài chết).
log "Dừng $AST"
docker stop "$AST" >/dev/null
on_exit() {
  rc=$?
  if [ "$(docker inspect -f '{{.State.Running}}' "$AST" 2>/dev/null)" != "true" ]; then
    docker start "$AST" >/dev/null && log "Đã khởi động lại $AST"
  fi
  [ $rc = 0 ] || echo "[$(date '+%F %T')] KHÔI PHỤC DỞ DANG (mã $rc). Trạng thái trước khôi phục nằm trong $(dirname "$SRC")/pre-restore" >&2
}
trap on_exit EXIT

# 3. Ghi đè file trong volume bằng một container tạm dùng chung volume với $AST (--volumes-from chạy được khi $AST dừng)
MOUNT_SRC="$SRC"
command -v cygpath >/dev/null && MOUNT_SRC="$(cygpath -m "$SRC")"   # chỉ khi chạy thử trên Git Bash/Windows
run_tmp() { MSYS_NO_PATHCONV=1 docker run --rm --volumes-from "$AST" -v "$MOUNT_SRC:/b:ro" --entrypoint sh "$IMAGE" -c "$1"; }
if has astdb; then
  run_tmp 'cp /b/astdb.sqlite3 /var/lib/asterisk/astdb/astdb.sqlite3 && rm -f /var/lib/asterisk/astdb/astdb.sqlite3-journal \
           && chown asterisk:asterisk /var/lib/asterisk/astdb/astdb.sqlite3'
  log "  astdb: đã khôi phục"
fi
# Giải nén ra thư mục tạm TRƯỚC; chỉ khi thành công mới xóa thư mục cũ và chép vào (file hỏng -> dữ liệu cũ còn nguyên)
restore_tar() {   # $1 = file trong bản sao lưu, $2 = thư mục đích trong container
  run_tmp "mkdir -p /tmp/r && tar -xzf /b/$1 -C /tmp/r && find $2 -mindepth 1 -delete && cp -a /tmp/r/. $2/ \
           && chown -R asterisk:asterisk $2"
}
if has astconf; then
  restore_tar astconf.tar.gz /etc/asterisk/gateway
  log "  astconf (group): đã khôi phục"
fi
if has astkeys; then
  restore_tar astkeys.tar.gz /etc/asterisk/keys
  log "  astkeys (chứng chỉ): đã khôi phục"
fi
if has astivr; then
  if [ -f "$SRC/astivr.tar.gz" ]; then
    restore_tar astivr.tar.gz /var/lib/asterisk/ivr
    log "  astivr (lời chào IVR): đã khôi phục"
  else
    log "  astivr: bản sao lưu cũ không có lời chào IVR -> giữ nguyên"
  fi
fi
if has db; then
  # --clean: xóa bảng cũ rồi tạo lại từ bản sao lưu. Lỗi nhỏ (vd quyền của role không còn) vẫn tiếp tục.
  docker exec -i "$DBC" pg_restore -U "$DB_USER" -d "$DB_NAME" --clean --if-exists --no-owner < "$SRC/db.dump" \
    || log "  db: pg_restore báo cảnh báo (xem trên); kiểm tra số dòng cdr bên dưới"
  log "  db: đã khôi phục"
fi

# 4. Khởi động lại và đối chiếu
log "Khởi động $AST"
docker start "$AST" >/dev/null
for i in $(seq 1 30); do
  docker exec "$AST" asterisk -rx "core show uptime" >/dev/null 2>&1 && break; sleep 2
done
N_EXT=$(docker exec "$AST" asterisk -rx "database show pjsip/endpoint" 2>/dev/null | grep -c '^/pjsip/endpoint/' || true)
N_GRP=$(docker exec "$AST" sh -c "grep -c '^\[' /etc/asterisk/gateway/queues-groups.conf 2>/dev/null || true")
N_IVR=$(docker exec "$AST" asterisk -rx "database show ivr" 2>/dev/null | grep -c '^/ivr/[^/]*/default ' || true)
N_CDR=$(docker exec "$DBC" psql -U "$DB_USER" -d "$DB_NAME" -tAc "SELECT count(*) FROM cdr" 2>/dev/null || echo "?")
echo
echo "Sau khôi phục:  extensions=$N_EXT  groups=${N_GRP:-0}  ivrs=$N_IVR  cdr_rows=$N_CDR"
echo "Bản sao lưu:    $(grep -E '^(extensions|groups|ivrs|cdr_rows)=' "$SRC/MANIFEST" | tr '\n' ' ')"
echo "Kiểm tra thêm: pjsip show endpoints, queue show, softphone đăng ký lại được. So .env với $SRC/env nếu đổi máy chủ."
