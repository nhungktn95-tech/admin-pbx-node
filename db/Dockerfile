# PostgreSQL 16 + tên múi giờ cũ (Asia/Saigon, US/Eastern...).
# Debian 13 tách các tên này ra gói tzdata-legacy; thiếu gói thì client Java trên Windows
# (DBeaver, PBX Gateway) gửi TimeZone=Asia/Saigon sẽ bị từ chối kết nối.
# "|| true": bản Debian cũ chưa tách gói thì bỏ qua (tên cũ vốn đã có sẵn).
FROM postgres:16

RUN apt-get update \
 && (apt-get install -y --no-install-recommends tzdata-legacy || true) \
 && rm -rf /var/lib/apt/lists/*
