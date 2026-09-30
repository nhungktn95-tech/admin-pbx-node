# Asterisk 20 LTS (gói chính thức của Ubuntu 24.04) + driver ODBC cho PostgreSQL
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      asterisk asterisk-modules asterisk-core-sounds-en asterisk-moh-opsound-wav \
      unixodbc odbc-postgresql gettext-base netcat-openbsd openssl tzdata \
 && rm -rf /var/lib/apt/lists/*

# Khai báo driver ODBC PostgreSQL (đường dẫn khác nhau giữa máy Intel và Apple Silicon)
RUN DRV=$(find /usr/lib -name psqlodbcw.so | head -1) \
 && printf "[PostgreSQL]\nDescription=PostgreSQL Unicode\nDriver=%s\n" "$DRV" > /etc/odbcinst.ini

# Cấu hình của mình: file *.tmpl sẽ được điền biến môi trường lúc khởi động
COPY conf/ /opt/pbx-conf/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 5060/udp 5038 8088 8089
ENTRYPOINT ["/entrypoint.sh"]
