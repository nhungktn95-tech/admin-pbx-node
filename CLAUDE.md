# CLAUDE.md — pbx-node (cụm tổng đài: Asterisk + Realtime DB)

Trả lời và viết tài liệu bằng **tiếng Việt**. Đọc hết file này trước khi làm.

> **Kiến trúc đã đổi (28/09/2026): BỎ pbx-agent.** Repo này chỉ còn Asterisk + PostgreSQL.
> Mọi quản trị đi qua **PBX Gateway** (repo `pbx-gateway`), Gateway chỉ kết nối **AMI 5038 + ARI 8088** của cụm này — **không dùng DB của cụm** (Bước G2, 05/10/2026).
> Mọi nội dung cũ về `agent/`, `/agent/v1`, `AGENT_API_KEY` đã hết hiệu lực — không làm nữa.

---

## 1. Bối cảnh

Dự án call AI hành chính công: người dân → nhà mạng (SIP trunk) → **Asterisk** → IVR (DTMF) → **AI** (Media server) → AI chuyển sang **group người thật**.

```
Admin UI / Phone AI / CRM ──REST──▶ PBX Gateway ──ARI 8088 (máy lẻ) / AMI 5038 (lệnh + sự kiện Cdr)──▶ Asterisk
                                                                     Asterisk ──▶ astdb (máy lẻ), PostgreSQL (queue, cdr)
Softphone, Media AI, nhà mạng ──SIP 5060 + RTP──▶ Asterisk
Softphone SDK (trình duyệt) ──WSS 8089 + SRTP──▶ Asterisk
```

4 repo: `pbx-node` (repo này) · `pbx-gateway` (Spring Boot) · `admin-pbx-ui` (React) · `pbx-softphone-sdk` (TypeScript).
Thoại **không** đi qua Gateway. Cần một cửa cho cả cuộc gọi thì sau này thêm SBC (Kamailio + RTPEngine) trước Asterisk.

## 2. Quyết định đã chốt (không tự ý đổi)

| Chủ đề | Quyết định |
| --- | --- |
| PBX | Asterisk thuần 20 LTS (gói Ubuntu 24.04), không FreePBX |
| Cấu hình | Máy lẻ PJSIP (endpoint/auth/aor): **astdb** của Asterisk, Gateway ghi qua ARI Push Configuration (G2). Group (queue): file `/etc/asterisk/gateway/queues-groups.conf` (volume `astconf`), Gateway sửa qua AMI `UpdateConfig` + `QueueReload` (G3). Hiệu lực ngay, không rớt cuộc gọi đang chờ. PostgreSQL chỉ còn bảng `cdr` |
| Quản trị | Chỉ PBX Gateway. AMI/ARI chỉ mở cho IP Gateway (mạng nội bộ/VPN + firewall). DB 5432 chỉ cho quản trị viên |
| User cho Gateway | AMI: `AMI_USER` (đọc có `cdr`; đọc/ghi `config` để quản lý group — sửa được MỌI file /etc/asterisk, nên AMI chỉ mở cho IP Gateway). ARI: `ARI_USER` (`read_only = no` để ghi máy lẻ). `GW_DB_USER` không còn dùng (giữ cho cụm cũ, có thể bỏ) |
| Quy ước số | **3 chữ số** (08/10/2026): **100–599 máy lẻ người dùng** · **600–999 group** · `*4x` số thử (`*43` âm thanh, `*44` phím bấm). **Web hay softphone KHÔNG theo đầu số** — do thuộc tính máy lẻ (`webrtc`, `transport`) quyết định, đổi loại máy không đổi số. **Không có dải số riêng cho AI.** Dialplan: `_[1-5]XX` → Dial, `_[6-9]XX` → Queue |
| Context | `from-internal` (người, web), `from-ai` (chỉ tới máy lẻ 100–599 và group 600–999), `from-trunk` (tra DID) |
| Phím bấm | `dtmf_mode=rfc4733` mọi máy lẻ |
| Máy web | `webrtc=yes`, `transport=transport-wss`, cổng WSS 8089 (http.conf, chứng chỉ tự ký ở lab) |
| Một máy lẻ | 3 đối tượng sorcery `aor`, `auth`, `endpoint` cùng `id` trong astdb (khóa `/pjsip/{loại}/{số}`, file `/var/lib/asterisk/astdb/astdb.sqlite3`, volume `astdb` — **phải sao lưu**). Bảng `ps_*` chỉ còn là bản lưu của dữ liệu cũ |
| Mật khẩu máy lẻ | Không lưu mật khẩu gốc. Đối tượng `auth`: `auth_type=md5`, `realm=asterisk`, `md5_cred=md5(username:asterisk:mật_khẩu)`, `password` rỗng. Gateway tự tính md5_cred khi tạo/đổi mật khẩu. Đổi `default_realm` = phải tính lại mọi md5_cred |
| Mật khẩu ARI | `ari.conf` lưu crypt SHA-512 (entrypoint băm từ `ARI_PASSWORD`). AMI buộc lưu dạng gốc (giới hạn của Asterisk) |
| Lịch sử | Bảng `cdr` (các dòng cùng `linkedid` là 1 cuộc gọi) + `cdr_manager.conf` gửi mỗi CDR thành sự kiện AMI `Cdr` (thêm `LinkedID`, `Sequence`, `RecordingFile`) — Gateway lưu lịch sử từ sự kiện này |
| Ghi âm | Mọi cuộc gọi đã nối máy (`MixMonitor` tùy chọn `b`, context `[sub-record]`), tắt bằng `RECORD_CALLS=no`. File WAV ở `/var/spool/asterisk/recording` (volume `recordings`) = thư mục ghi âm của ARI → Gateway liệt kê/tải/xóa qua ARI `/recordings/stored`. Tên file (không đuôi) lưu ở `cdr.recordingfile`. **Không tự xóa** file |

## 3. Trạng thái

- Bước 1–3 cũ (gọi nhau, group 600, thêm máy lẻ bằng SQL): **xong**.
- **Bước G1 — mở cho Gateway + WSS: bản tham chiếu đã làm xong và kiểm tra** (xem mục 4). Cần áp vào repo thật.
- Tiếp theo nằm ở repo `pbx-gateway` (Bước 2: Server Management).
- **Bước G2 — Gateway không dùng DB của cụm (05/10/2026): đã làm, thử trên cụm Docker cục bộ** (xem mục 4b). Chưa áp lên lab-02.

## 4c. Bước G3 — group trong queues-groups.conf, Gateway quản lý qua AMI (06/10/2026, đã thử trên Docker cục bộ)

Theo phương án [docs/phuong-an-queue-qua-ami.md](docs/phuong-an-queue-qua-ami.md) (cách 1). Khác phương án: **không dùng symlink** — AMI chặn
GetConfig/UpdateConfig khi đường dẫn thật của file nằm ngoài `/etc/asterisk` ("File requires escalated priveledges"), nên volume `astconf`
gắn thẳng vào `/etc/asterisk/gateway`, `queues.conf` chỉ còn `[general]` + `#include gateway/queues-groups.conf`.

| File | Thay đổi |
| --- | --- |
| `asterisk/conf/queues.conf` | `[general]` + `#include gateway/queues-groups.conf` |
| `asterisk/conf/queues-groups.conf` (mới) | bản mẫu group 600, chỉ chép vào volume khi trống |
| `asterisk/conf/extconfig.conf` | bỏ `queues`, `queue_members` |
| `asterisk/conf/manager.conf.tmpl` | thêm `config` vào read/write |
| `asterisk/entrypoint.sh` | không chép đè `queues-groups.conf`; tạo `/etc/asterisk/gateway` + chép bản mẫu khi trống |
| `docker-compose.yml` | volume `astconf:/etc/asterisk/gateway` (**sao lưu** cùng `astdb`) |
| `scripts/chuyen-group-sang-queues-conf.sh` (mới) | chuyển group cũ từ bảng `queues`/`queue_members` (thứ tự theo uniqueid) |
| `scripts/check-gateway-access.sh` | thử AMI `GetConfig gateway/queues-groups.conf` |

Đã thử: `GetConfig`; `UpdateConfig` NewCat/Append (tạo), DelCat + NewCat trong một lệnh (sửa, đổi thứ tự member — `QueueStatus` trả đúng thứ tự),
DelCat + `QueueReload` không tham số (xóa queue đang chạy); NewCat trùng → lỗi; restart giữ nguyên. Luôn ghi `ringinuse = no` (mặc định Asterisk là yes).
Chưa thử: `QueueReload` khi đang có người chờ trong queue.

Áp lên cụm đang chạy: `git pull` → `docker compose up -d --build` → `sh scripts/chuyen-may-le-sang-astdb.sh` (nếu chưa G2) → `sh scripts/chuyen-group-sang-queues-conf.sh`.

## 4b. Bước G2 — máy lẻ trong astdb + CDR qua AMI

Lý do: PBX Gateway không được phụ thuộc database của cụm. Asterisk có sẵn ARI Push Configuration để tạo máy lẻ, nhưng
**không dùng được với realtime PostgreSQL**: khi ghi qua ARI, `res_config_odbc`/`res_config_pgsql` INSERT mọi thuộc tính mà
không đặt tên cột trong nháy kép → cột `100rel` của endpoint gây lỗi cú pháp; `update_odbc` còn hỏng khi đối tượng > 64 thuộc tính.
Đã thử, xem lịch sử commit. Vì vậy chuyển 3 loại đối tượng PJSIP sang `astdb`.

| File | Thay đổi |
| --- | --- |
| `asterisk/conf/sorcery.conf` | `endpoint/auth/aor = astdb,pjsip` |
| `asterisk/conf/extconfig.conf` | bỏ `ps_*`, chỉ còn `queues`, `queue_members` |
| `asterisk/conf/cdr_manager.conf` (mới) | bật sự kiện AMI `Cdr`, mappings `linkedid`, `sequence`, `recordingfile` |
| `asterisk/entrypoint.sh` | bỏ `(!)` của `[directories]` trong asterisk.conf (gói Ubuntu để template nên mục bị bỏ qua) và đặt `astdbdir => /var/lib/asterisk/astdb` |
| `docker-compose.yml` | volume `astdb:/var/lib/asterisk/astdb` |
| `scripts/chuyen-may-le-sang-astdb.sh` (mới) | chuyển máy lẻ cũ từ `ps_*` sang astdb qua ARI, giữ `md5_cred` |
| `scripts/check-gateway-access.sh` | bỏ kiểm tra DB; thêm thử ARI tạo + xóa aor tạm |

Đã kiểm tra trên cụm Docker cục bộ: ARI tạo/sửa/xóa máy lẻ, restart Asterisk vẫn còn; script chuyển 15 đối tượng seed, md5 giữ nguyên;
REGISTER UDP có digest: đúng mật khẩu 200, sai 401; sự kiện `Cdr` có `LinkedID`, `Sequence`, `RecordingFile`.

Áp lên cụm đang chạy (lab-02…): `git pull` → `docker compose up -d --build` → **ngay sau đó** `sh scripts/chuyen-may-le-sang-astdb.sh`
(giữa hai lệnh máy lẻ cũ tạm không đăng ký được) → `asterisk -rx "pjsip show endpoints"`.
Lưu ý: `pjsip show endpoints` (CLI) hiện mỗi máy hai lần với astdb — chỉ là hiển thị, mỗi số một bản ghi trong astdb.

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
- Docker bridge: `external_media_address`/`external_signaling_address` = `HOST_IP`; `local_net` = `127.0.0.1/32` + `${CONTAINER_IP}/32` (IP của chính Asterisk). Thiếu IP container thì Asterisk KHÔNG thay IP âm thanh trong SDP (vẫn `c=IN IP4 172.x`) → softphone thường (Linphone, MicroSIP) mất tiếng; máy web vẫn chạy nhờ ICE. KHÔNG thêm dải LAN (192.168.x), KHÔNG dùng cả dải `172.16.0.0/12` (chứa cổng Docker `172.x.0.1` = nguồn của softphone cùng máy/Docker Desktop → Contact/SDP là IP container → ngắt ở giây 32).
- Container Asterisk có `hostname: pbx-asterisk` (bắt đầu bằng chữ cái). Hostname mặc định = mã container, bắt đầu bằng chữ số thì sai chuẩn SIP trong From/Contact qua WebSocket → JsSIP bỏ gói → máy web `Unavail`, không nhận được cuộc gọi.
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
