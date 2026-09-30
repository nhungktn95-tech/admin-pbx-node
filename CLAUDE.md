# CLAUDE.md — pbx-node (cụm tổng đài: Asterisk + Realtime DB)

Trả lời và viết tài liệu bằng **tiếng Việt**. Đọc hết file này trước khi làm.

> **Kiến trúc đã đổi (28/09/2026): BỎ pbx-agent.** Repo này chỉ còn Asterisk + PostgreSQL.
> Mọi quản trị đi qua **PBX Gateway** (repo `pbx-gateway`), Gateway kết nối thẳng vào DB 5432, AMI 5038, ARI 8088 của cụm này.
> Mọi nội dung cũ về `agent/`, `/agent/v1`, `AGENT_API_KEY` đã hết hiệu lực — không làm nữa.

---

## 1. Bối cảnh

Dự án call AI hành chính công: người dân → nhà mạng (SIP trunk) → **Asterisk** → IVR (DTMF) → **AI** (Media server) → AI chuyển sang **group người thật**.

```
Admin UI / Phone AI / CRM ──REST──▶ PBX Gateway ──SQL 5432──▶ Realtime DB ◀── Asterisk đọc
                                          └────AMI 5038 / ARI 8088──▶ Asterisk
Softphone, Media AI, nhà mạng ──SIP 5060 + RTP──▶ Asterisk
Softphone SDK (trình duyệt) ──WSS 8089 + SRTP──▶ Asterisk
```

4 repo: `pbx-node` (repo này) · `pbx-gateway` (Spring Boot) · `admin-pbx-ui` (React) · `pbx-softphone-sdk` (TypeScript).
Thoại **không** đi qua Gateway. Cần một cửa cho cả cuộc gọi thì sau này thêm SBC (Kamailio + RTPEngine) trước Asterisk.

## 2. Quyết định đã chốt (không tự ý đổi)

| Chủ đề | Quyết định |
| --- | --- |
| PBX | Asterisk thuần 20 LTS (gói Ubuntu 24.04), không FreePBX |
| Cấu hình | Realtime DB PostgreSQL: máy lẻ, queue (sau: DID, IVR) → hiệu lực ngay, không reload |
| Quản trị | Chỉ PBX Gateway. DB/AMI/ARI chỉ mở cho IP Gateway (mạng nội bộ/VPN + firewall) |
| User cho Gateway | DB: `GW_DB_USER` (ghi ps_*, queues, queue_members; chỉ đọc cdr). AMI: `AMI_USER`. ARI: `ARI_USER` |
| Quy ước số | 1xx người · 15x máy web (WebRTC) · 2xx AI · 6xx group · 9000 giả nhà mạng (lab) |
| Context | `from-internal` (người, web), `from-ai` (chỉ tới 1xx/6xx), `from-trunk` (tra DID) |
| Phím bấm | `dtmf_mode=rfc4733` mọi máy lẻ |
| Máy web | `webrtc=yes`, `transport=transport-wss`, cổng WSS 8089 (http.conf, chứng chỉ tự ký ở lab) |
| Một máy lẻ | 1 dòng ở 3 bảng `ps_aors`, `ps_auths`, `ps_endpoints` cùng `id` |
| Mật khẩu máy lẻ | Không lưu mật khẩu gốc. `ps_auths`: `auth_type='md5'`, `realm='asterisk'`, `md5_cred=md5(username:asterisk:mật_khẩu)`, `password=NULL` (CHECK constraint bắt buộc). Gateway tự tính md5_cred khi tạo/đổi mật khẩu. Đổi `default_realm` = phải tính lại mọi md5_cred |
| Mật khẩu ARI | `ari.conf` lưu crypt SHA-512 (entrypoint băm từ `ARI_PASSWORD`). AMI buộc lưu dạng gốc (giới hạn của Asterisk) |
| Lịch sử | Bảng `cdr`, các dòng cùng `linkedid` là 1 cuộc gọi |

## 3. Trạng thái

- Bước 1–3 cũ (gọi nhau, group 600, thêm máy lẻ bằng SQL): **xong**.
- **Bước G1 — mở cho Gateway + WSS: bản tham chiếu đã làm xong và kiểm tra** (xem mục 4). Cần áp vào repo thật.
- Tiếp theo nằm ở repo `pbx-gateway` (Bước 2: Server Management).

## 4. Bước G1 — Mở kết nối cho PBX Gateway + bật WSS

### 4.1 Việc cần làm trong repo thật

Repo thật trên máy có thể khác bản tham chiếu (có `all-in-one/`, `Dockerfile` ở gốc, `docker-compose.host.yml`).
**Trước khi sửa: đọc cấu trúc repo, liệt kê file sẽ đổi, BÁO CÁO rồi mới làm.** Nếu còn `all-in-one/` thì gộp cấu hình về `asterisk/conf/` trước (một nguồn duy nhất). Commit + tag trước khi sửa để quay lại được.

| File | Thay đổi |
| --- | --- |
| `asterisk/conf/manager.conf.tmpl` (mới) | AMI bind 0.0.0.0:5038; user `${AMI_USER}` / `${AMI_SECRET}`; `deny` tất cả, `permit` `${GATEWAY_IP}`, 127.0.0.1, `${AMI_PERMIT_EXTRA}`; read: system, call, agent, user, dtmf, reporting, cdr; write: system, call, agent, user, originate, reporting |
| `asterisk/conf/http.conf.tmpl` (mới) | HTTP 8088 (ARI), HTTPS 8089 (`tlsenable`, cert `/etc/asterisk/keys/asterisk.crt` + `.key`) |
| `asterisk/conf/ari.conf.tmpl` (mới) | user `${ARI_USER}` / `${ARI_PASSWORD}` |
| `asterisk/conf/pjsip.conf.tmpl` | thêm `[transport-wss]` protocol=wss, bind=0.0.0.0, external_* = `${HOST_IP}` |
| `asterisk/conf/rtp.conf.tmpl` | thêm `icesupport = yes` |
| `asterisk/entrypoint.sh` | thêm vào `VARS`: GATEWAY_IP, AMI_USER, AMI_SECRET, AMI_PERMIT_EXTRA, ARI_USER, ARI_PASSWORD; mặc định GATEWAY_IP=127.0.0.1, AMI_PERMIT_EXTRA=172.16.0.0/255.240.0.0; báo lỗi nếu thiếu AMI_SECRET/ARI_PASSWORD; tự tạo chứng chỉ tự ký (openssl, SAN = IP:${HOST_IP}) nếu chưa có |
| `asterisk/Dockerfile` | thêm gói `openssl`; EXPOSE 5038 8088 8089 |
| `db/init/01-schema.sql` | `ps_endpoints` thêm cột `webrtc VARCHAR(3)` |
| `db/init/02-seed.sql` | thêm máy web 150, 151 (`transport-wss`, `webrtc=yes`) |
| `db/init/03-gateway-user.sh` (mới) | tạo/cập nhật role `GW_DB_USER`, GRANT như mục 2; chạy lại nhiều lần được |
| `sql/gw1-nang-cap-db-cu.sql` (mới) | cho DB đã có dữ liệu: `ADD COLUMN IF NOT EXISTS webrtc` + 150/151 `ON CONFLICT DO NOTHING` |
| `docker-compose.yml` | db: truyền `GW_DB_USER/GW_DB_PASSWORD`, cổng `${ADMIN_BIND:-0.0.0.0}:5432`; asterisk: thêm 8089, `${ADMIN_BIND}:5038`, `${ADMIN_BIND}:8088`, volume `astkeys:/etc/asterisk/keys` |
| `docker-compose.host.yml` (nếu có) | chế độ host không cần map cổng; Postgres phải nghe IP nội bộ (không chỉ 127.0.0.1) để Gateway vào được |
| `.env.example` | thêm GATEWAY_IP, AMI_PERMIT_EXTRA, ADMIN_BIND, AMI_USER, AMI_SECRET, ARI_USER, ARI_PASSWORD, GW_DB_USER, GW_DB_PASSWORD |
| `scripts/check-gateway-access.sh` (mới) | chạy trên máy Gateway: cổng, đăng nhập AMI, DB đọc/ghi được + không sửa được cdr, ARI 200, WSS 400/426 |
| Bỏ | mọi thứ liên quan `agent/` nếu đã lỡ tạo |

Bản tham chiếu đầy đủ nằm trong zip `pbx-node` gửi kèm: so sánh và lấy nội dung từ đó.

### 4.2 Áp dụng cho DB đã chạy từ trước (volume `pgdata` có dữ liệu)

Script trong `db/init/` chỉ tự chạy ở lần đầu, nên chạy tay:

```bash
docker compose up -d --build
docker compose exec -T db psql -U asterisk -d asterisk < sql/gw1-nang-cap-db-cu.sql
docker compose exec db sh /docker-entrypoint-initdb.d/03-gateway-user.sh
```

### 4.3 Xong khi

- `./scripts/check-gateway-access.sh <HOST_IP> .env` chạy **từ máy Gateway** (hoặc cùng máy ở lab) ra toàn OK.
- `asterisk -rx "pjsip show endpoint 150"` thấy `webrtc: yes`, `media_encryption: dtls`, `ice_support: true`.
- Bước 1–3 cũ vẫn chạy (101 gọi 102, gọi 600).

## 5. Lưu ý kỹ thuật (đừng lặp lại lỗi)

Checklist triển khai đầy đủ (kèm triệu chứng khi làm sai): [docs/luu-y-trien-khai.md](docs/luu-y-trien-khai.md). Có lỗi triển khai mới thì bổ sung vào file đó.

- `modules.conf`: `preload => res_odbc.so`, `preload => res_config_odbc.so` (Ubuntu mặc định noload), `noload => chan_sip.so`, tắt `app_voicemail_odbc.so`, `app_voicemail_imap.so`.
- `queue_members` cần cột `reason_paused` (Asterisk 20).
- `entrypoint.sh` dùng `envsubst` với **danh sách biến cố định** để không thay `${EXTEN}` trong dialplan. Thêm biến mới = thêm vào `VARS`.
- Docker bridge: `external_media_address`/`external_signaling_address` = `HOST_IP`; `local_net` = `127.0.0.1/32` + `172.16.0.0/12` (mạng Docker). Thiếu dải Docker thì Asterisk KHÔNG thay IP âm thanh trong SDP (vẫn `c=IN IP4 172.x`) → softphone thường (Linphone, MicroSIP) mất tiếng; máy web vẫn chạy nhờ ICE. KHÔNG thêm dải LAN (192.168.x) vào local_net.
- WebRTC trong Docker: `rtp.conf` có `[ice_host_candidates]` `${CONTAINER_IP} => ${HOST_IP}` (entrypoint lấy `CONTAINER_IP` bằng `hostname -i`). Thiếu thì Asterisk gửi ICE candidate 172.x → trình duyệt trên máy có card ảo (Docker Desktop/WSL) chọn nhầm đường, Asterisk không nhận tiếng (channelstats Receive = 0).
- Giá trị yes/no trong bảng Realtime lưu dạng chữ `'yes'`/`'no'`.
- AMI qua Docker bridge: kết nối từ chính máy chủ đi vào với IP nguồn `172.x` (mạng Docker), nên lab cần `AMI_PERMIT_EXTRA=172.16.0.0/255.240.0.0`. Môi trường thật đặt = IP Gateway.
- AMI không mã hóa: không bao giờ mở 5038 ra Internet.
- Trình duyệt phải tin chứng chỉ tự ký: mở `https://HOST_IP:8089/ws` một lần, chọn Advanced → Proceed.
- JsSIP phải gửi phím bằng `sendDTMF(d, { transportType: 'RFC2833' })`.

## 6. Cách làm việc

- Thiết kế trao đổi ở một cuộc chat Claude riêng; file này cập nhật khi có quyết định mới. Luôn đọc lại trước khi làm.
- Làm từng phần, liệt kê file sẽ đổi trước khi sửa; cập nhật README (cách chạy, cách kiểm tra).
- Không commit `.env`. Không hard-code IP, mật khẩu.
