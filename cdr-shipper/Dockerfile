# cdr-shipper: giao bảng cdr của cụm sang PBX Gateway (docs/cdr-shipper.md)
FROM python:3.12-alpine

RUN apk add --no-cache tzdata \
 && pip install --no-cache-dir "psycopg[binary]==3.2.*" \
 && adduser -D -H -u 10001 shipper \
 && mkdir -p /state && chown shipper:shipper /state

COPY shipper.py /app/shipper.py
USER shipper
# /state là volume giữ mốc đã giao (last_acked_id); volume mới tạo lấy quyền sở hữu từ thư mục này
VOLUME ["/state"]
ENTRYPOINT ["python", "-u", "/app/shipper.py"]
