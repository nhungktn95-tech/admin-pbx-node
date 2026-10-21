#!/bin/bash
# ============================================================
# Chạy trên máy Ubuntu sau mỗi lần chép code từ Windows sang:
#   bash scripts/deploy.sh
# Việc làm: sửa quyền file (Windows không giữ quyền Linux), bỏ CRLF,
# kiểm tra .env, build + chạy lại container.
# ============================================================
set -e
cd "$(dirname "$0")/.."

if [ ! -f .env ]; then
  echo "LỖI: chưa có .env -> cp .env.example .env rồi sửa HOST_IP, GATEWAY_IP, mật khẩu" >&2
  exit 1
fi

# 1. Quyền: thư mục 755, file 644, script 755, .env chỉ chủ sở hữu đọc
find . -type d ! -path './.git*' -exec chmod 755 {} +
find . -type f ! -path './.git/*' -exec chmod 644 {} +
chmod 755 asterisk/entrypoint.sh db/init/*.sh scripts/*.sh
chmod 600 .env

# 2. Xuống dòng CRLF -> LF (phòng khi file được lưu trên Windows)
grep -rlI $'\r' --exclude-dir=.git . | xargs -r sed -i 's/\r$//'

# 3. HOST_IP trong .env phải là IP của máy này
HOST_IP=$(grep -E '^HOST_IP=' .env | cut -d= -f2)
if ! hostname -I | tr ' ' '\n' | grep -qx "$HOST_IP"; then
  echo "CẢNH BÁO: HOST_IP=$HOST_IP không phải IP của máy này ($(hostname -I))" >&2
fi

# 4. Build + chạy
docker compose up -d --build
docker compose ps
