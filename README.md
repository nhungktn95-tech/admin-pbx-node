# pbx-node — Máy tổng đài lab (Asterisk 20 + PostgreSQL)

Project này dựng **máy tổng đài** trong kiến trúc Admin PBX, làm 3 bước đầu:

| Bước | Làm gì | Hiểu được gì |
| --- | --- | --- |
| 1 | Chạy tổng đài, 2 softphone đăng nhập 101 và 102, gọi nhau | Máy lẻ, đăng nhập (register), SIP/RTP, dialplan |
| 2 | Gọi group 600 → đổ chuông 101 + 102 | Group (queue), chiến lược đổ chuông |
| 3 | Thêm máy lẻ 103 bằng một câu SQL khi tổng đài đang chạy | Realtime DB — nền tảng để PBX Gateway tạo máy lẻ sau này |
| G1 | Mở DB, AMI, ARI cho PBX Gateway; bật WSS + máy lẻ web 150/151 | Gateway quản trị cụm từ xa; trình duyệt gọi được |

Project này **chỉ gồm Asterisk + Realtime DB**. Việc quản trị (tạo máy lẻ, group, thống kê) do **PBX Gateway** (repo `pbx-gateway`) làm từ xa qua DB, AMI, ARI.

---

## Cấu trúc thư mục

```
pbx-node/
├─ docker-compose.yml          # 2 container: db (PostgreSQL) + asterisk
├─ .env.example                # thông số theo từng nơi triển khai -> copy thành .env
├─ asterisk/
│  ├─ Dockerfile               # Ubuntu 24.04 + Asterisk 20 LTS + driver ODBC PostgreSQL
│  ├─ entrypoint.sh            # điền .env vào cấu hình, chờ DB, chạy Asterisk
│  └─ conf/                    # cấu hình Asterisk (sửa ở đây)
│     ├─ modules.conf          # nạp module (ODBC trước PJSIP, tắt chan_sip cũ)
│     ├─ res_odbc.conf.tmpl    # Asterisk -> PostgreSQL
│     ├─ odbc.ini.tmpl         #   (địa chỉ DB)
│     ├─ extconfig.conf        # bảng nào đọc từ DB
│     ├─ sorcery.conf          # PJSIP đọc máy lẻ từ DB
│     ├─ pjsip.conf.tmpl       # chỉ có transport (UDP 5060, WSS), KHÔNG có máy lẻ
│     ├─ manager.conf.tmpl     # AMI 5038 cho Gateway
│     ├─ http.conf.tmpl, ari.conf.tmpl  # ARI 8088, WSS 8089
│     ├─ rtp.conf.tmpl         # dải cổng âm thanh
│     ├─ extensions.conf       # DIALPLAN: gọi 1xx/2xx, gọi group 6xx, *43 thử âm thanh
│     ├─ queues.conf           # group đọc từ DB
│     ├─ cdr.conf, cdr_adaptive_odbc.conf   # ghi lịch sử cuộc gọi vào bảng cdr
├─ db/init/
│  ├─ 01-schema.sql            # tạo bảng: ps_endpoints, ps_auths, ps_aors, queues, queue_members, cdr
│  ├─ 02-seed.sql              # dữ liệu mẫu: 101, 102, 201 (+ máy web 150, 151), group 600
│  └─ 03-gateway-user.sh       # user DB riêng cho PBX Gateway
├─ scripts/check-gateway-access.sh   # chạy trên máy Gateway để kiểm tra kết nối
└─ sql/                        # câu SQL cho bước 3, nâng cấp DB cũ, xem dữ liệu
```

File `.tmpl` chứa biến như `${HOST_IP}`; lúc container khởi động, `entrypoint.sh` điền giá trị từ `.env` vào rồi mới chạy Asterisk.

---

## Chuẩn bị

> **Triển khai lên máy chủ Ubuntu:** đọc [docs/luu-y-trien-khai.md](docs/luu-y-trien-khai.md) trước (chép code, quyền file, firewall, NAT Docker, WSS, xử lý mất tiếng).

1. **Docker Desktop** (Windows/macOS) hoặc Docker Engine (Linux).
2. **Softphone** trên 2 thiết bị, cùng mạng Wi-Fi/LAN với máy chạy Docker:
   - Máy tính Windows: **MicroSIP** (miễn phí) · macOS/Windows: **Zoiper 5**
   - Điện thoại: **Zoiper** (Android/iOS)
3. Lấy **IP LAN** của máy chạy Docker:
   - Windows: `ipconfig` → dòng *IPv4 Address* (ví dụ `192.168.1.10`)
   - macOS: `ipconfig getifaddr en0`
   - Linux: `hostname -I`
4. Tạo file cấu hình:
   ```bash
   cp .env.example .env
   # mở .env, sửa HOST_IP=<IP LAN vừa lấy>
   ```
5. Mở firewall cho **UDP 5060** và **UDP 10000–10099** (Windows Defender Firewall sẽ hỏi khi Docker chạy lần đầu → chọn *Allow*).

---

## Khởi động

```bash
docker compose up -d --build        # lần đầu mất vài phút để build image
docker compose ps                   # 2 container: pbx-db (healthy), pbx-asterisk (running)
docker compose logs -f asterisk     # xem log, Ctrl+C để thoát
```

Vào **màn hình lệnh của Asterisk** (dùng rất nhiều trong các bước dưới):

```bash
docker compose exec asterisk asterisk -rvvv
```

Gõ `exit` để thoát (Asterisk vẫn chạy).

---

## Bước 1 — Hai máy lẻ gọi nhau

**1.1 Xem máy lẻ Asterisk đọc từ DB** (trong màn hình lệnh Asterisk):

```
pjsip show endpoints
```

Thấy 101, 102, 201 trạng thái `Unavailable` (chưa có thiết bị nào đăng nhập).

**1.2 Đăng nhập softphone**

| Thông số | Thiết bị 1 | Thiết bị 2 |
| --- | --- | --- |
| Domain / Server | `HOST_IP` (ví dụ 192.168.1.10) | `HOST_IP` |
| Port / Transport | 5060 / UDP | 5060 / UDP |
| Username | `101` | `102` |
| Password | `lab101pass` | `lab102pass` |

MicroSIP: *Menu → Add account*, điền *SIP Server*, *Username*, *Password*.
Zoiper: *Settings → Accounts → Add → SIP*, điền *Username* dạng `101@192.168.1.10`, *Password*.

Kiểm tra: `pjsip show contacts` → thấy `101/sip:101@...` và `102/...` trạng thái `Avail`.

**1.3 Thử âm thanh:** từ 101 bấm `*43` → nghe lời hướng dẫn, nói gì nghe lại nấy. Không nghe gì = sai `HOST_IP` hoặc firewall chặn RTP (xem *Lỗi thường gặp*).

**1.4 Gọi 101 → 102:** 102 đổ chuông, nghe máy, nói chuyện được.

**Chuyện gì xảy ra bên trong:**
1. Softphone 101 gửi *REGISTER* kèm mật khẩu → Asterisk tra bảng `ps_auths` → đúng thì ghi nhận "101 đang ở IP này".
2. 101 bấm 102 → gửi *INVITE* → Asterisk xem cột `context` của 101 trong `ps_endpoints` = `from-internal` → chạy dialplan `[from-internal]` trong `extensions.conf`, khớp mẫu `_[12]XX` → `Dial(PJSIP/102)`.
3. Hai bên nghe máy → âm thanh đi qua cổng RTP 10000–10099.

Mẹo: bật `pjsip set logger on` trong màn hình lệnh để xem từng bản tin SIP (tắt bằng `pjsip set logger off`).

---

## Bước 2 — Group 600

```
queue show 600
```

Thấy strategy `ringall`, thành viên `PJSIP/101`, `PJSIP/102` (realtime).

**Gọi group:** đăng nhập thêm máy **201** (`lab201pass`) trên thiết bị thứ 3 — hoặc tạm đổi tài khoản thiết bị 1 sang 201 — rồi bấm **600** → cả 101 và 102 đổ chuông cùng lúc, ai nhấc trước thì nghe.

(Nếu chỉ có 2 thiết bị: từ 101 gọi 600 → chỉ 102 đổ chuông, vì 101 đang bận gọi.)

**Đổi chiến lược đổ chuông** — sửa DB, không cần khởi động lại:

```bash
docker compose exec db psql -U asterisk -d asterisk \
  -c "UPDATE queues SET strategy='rrmemory' WHERE name='600';"
```

Gọi 600 vài lần: lần lượt 101 rồi 102 đổ chuông (xoay vòng). Đặt lại `ringall` để đổ tất cả.

---

## Bước 3 — Thêm máy lẻ 103 khi tổng đài đang chạy

Đây chính là việc PBX Gateway sẽ làm tự động sau này.

```bash
docker compose exec -T db psql -U asterisk -d asterisk < sql/buoc3-them-may-le-103.sql
```

Ngay lập tức, **không reload**:

```
pjsip show endpoint 103     # đã có 103
queue show 600              # 103 đã là thành viên group 600
```

Đăng nhập softphone bằng `103` / `lab103pass` → gọi được, và gọi 600 thì 103 cũng đổ chuông.

**Thử thêm:**

- Đổi mật khẩu 103 → đăng nhập bằng mật khẩu cũ bị từ chối ngay:
  ```bash
  docker compose exec db psql -U asterisk -d asterisk \
    -c "UPDATE ps_auths SET md5_cred=md5('103:asterisk:matkhaumoi') WHERE id='103';"
  ```
  DB không lưu mật khẩu gốc: chỉ lưu `md5_cred = md5('<user>:asterisk:<mật khẩu>')` (cột `password` luôn trống, DB từ chối nếu ghi vào).
- Xóa 103 để làm lại: `docker compose exec -T db psql -U asterisk -d asterisk < sql/buoc3-xoa-may-le-103.sql`

**Một máy lẻ = 1 dòng ở 3 bảng:**

| Bảng | Chứa gì |
| --- | --- |
| `ps_endpoints` | Cách gọi: context dialplan, codec, caller ID, kiểu truyền phím (`dtmf_mode`) |
| `ps_auths` | Username / mật khẩu đăng nhập |
| `ps_aors` | Được đăng nhập mấy thiết bị cùng lúc, bao lâu kiểm tra thiết bị còn sống |

---

## Xem lịch sử cuộc gọi

Sau mỗi cuộc gọi, Asterisk tự ghi 1 dòng vào bảng `cdr`:

```bash
docker compose exec -T db psql -U asterisk -d asterisk < sql/xem-du-lieu.sql
```

Ví dụ kết quả thật khi chạy thử project này:

| src | dst | lastapp | dstchannel | disposition | billsec |
| --- | --- | --- | --- | --- | --- |
| 101 | 600 | Queue | PJSIP/102-00000001 | ANSWERED | 6 |
| 101 | 102 | Dial | PJSIP/102-00000003 | ANSWERED | 6 |
| 101 | 103 | Dial | PJSIP/103-00000005 | ANSWERED | 6 |

Có thể dùng **DBeaver** kết nối `localhost:5432`, database `asterisk`, user/pass trong `.env` để xem trực quan.

---

## Lệnh hay dùng

| Việc | Lệnh |
| --- | --- |
| Khởi động / dừng | `docker compose up -d` / `docker compose down` |
| Sửa file trong `asterisk/conf/` xong | `docker compose restart asterisk` |
| Sửa riêng dialplan, không restart | trong màn hình lệnh Asterisk: `dialplan reload` |
| Xóa sạch dữ liệu, chạy lại seed từ đầu | `docker compose down -v && docker compose up -d` |
| Máy lẻ đang đăng nhập | `pjsip show contacts` |
| Cuộc gọi đang diễn ra | `core show channels` |

---

## Lỗi thường gặp

| Hiện tượng | Nguyên nhân thường gặp | Cách xử lý |
| --- | --- | --- |
| Softphone báo *Request Timeout*, không đăng nhập được | Sai `HOST_IP`/server, firewall chặn UDP 5060, khác mạng | Kiểm tra IP, mở firewall, `pjsip set logger on` xem có REGISTER tới không |
| Báo *401/403 Forbidden* | Sai username/mật khẩu | So với bảng `ps_auths` |
| Gọi được nhưng không nghe tiếng / nghe một chiều | `HOST_IP` sai, firewall chặn UDP 10000–10099 | Sửa `.env` → `docker compose up -d`, mở firewall |
| `pjsip show endpoints` trống | Asterisk không kết nối được DB | `odbc show` trong màn hình lệnh phải thấy *active connections: 1*; xem `docker compose logs asterisk` |
| Sửa `02-seed.sql` nhưng không thấy đổi | Script init chỉ chạy lần đầu | `docker compose down -v && docker compose up -d` |

---

## Bước G1 — Mở kết nối cho PBX Gateway + bật WSS

PBX Gateway (máy khác, hoặc cùng máy ở lab) cần vào được 3 cổng của cụm này. Trình duyệt cần cổng WSS để gọi điện.

| Cổng | Dùng cho | Ai được vào |
| --- | --- | --- |
| 5432/tcp | Realtime DB — Gateway ghi máy lẻ/group, đọc CDR | Chỉ IP Gateway |
| 5038/tcp | AMI — trạng thái, lệnh | Chỉ IP Gateway (AMI không mã hóa) |
| 8088/tcp | ARI — dùng ở giai đoạn 2 | Chỉ IP Gateway |
| 8089/tcp | WSS — Softphone SDK trong trình duyệt | Người dùng nội bộ |

**1. Cập nhật `.env`** (so với `.env.example`, thêm các dòng mục *Kết nối cho PBX Gateway*): `GATEWAY_IP`, `AMI_SECRET`, `ARI_PASSWORD`, `GW_DB_PASSWORD`… Lab chạy Gateway cùng máy thì `GATEWAY_IP` để IP máy này.

**2. Khởi động lại**

```bash
docker compose up -d --build
```

Nếu DB đã tạo từ trước (các bước 1–3), chạy thêm 2 lệnh (DB mới tạo thì bỏ qua):

```bash
docker compose exec -T db psql -U asterisk -d asterisk < sql/gw1-nang-cap-db-cu.sql
docker compose exec db sh /docker-entrypoint-initdb.d/03-gateway-user.sh
```

**3. Kiểm tra trong Asterisk**

```
manager show settings            # Manager (AMI): Yes, 0.0.0.0:5038
http show status                 # 8088 và HTTPS 8089, có /ari và /ws
pjsip show transports            # transport-udp và transport-wss
pjsip show endpoint 150          # webrtc: yes, media_encryption: dtls, ice_support: true
```

**4. Kiểm tra từ máy Gateway** (cần `nc`, `psql`, `curl`; chép `scripts/` và `.env` sang):

```bash
./scripts/check-gateway-access.sh 192.168.1.10 .env
```

Kết quả mong đợi — toàn OK:

```
1) Cổng mạng            OK tcp/5432, 5038, 8088, 8089 mở
2) AMI                  OK đăng nhập AMI, Asterisk 20.x
3) Realtime DB          OK đọc ps_endpoints / có quyền ghi / đọc được cdr / không có quyền sửa cdr (đúng)
4) ARI                  OK ARI trả 200
5) WSS                  OK https://…:8089/ws trả 426 (WSS sẵn sàng)
=> Bước 1 xong: Gateway kết nối được.
```

**Lỗi thường gặp:**
- *AMI từ chối*: sai `AMI_SECRET`, hoặc IP Gateway không nằm trong `permit` → xem `GATEWAY_IP`, `AMI_PERMIT_EXTRA`. Sau khi sửa `.env`: `docker compose up -d` (tạo lại container).
- *Không vào được 5432 từ máy khác*: firewall máy chủ, hoặc `ADMIN_BIND` đang là 127.0.0.1.
- *Trình duyệt không kết nối WSS*: chứng chỉ tự ký → mở `https://HOST_IP:8089/ws` một lần, chọn *Advanced → Proceed*.

## Lộ trình tiếp theo

| Bước | Nội dung | Ở đâu |
| --- | --- | --- |
| 4 | Menu IVR bấm phím (DTMF), số gọi vào (DID); máy 9000 giả làm nhà mạng | pbx-node: `did_routes`, `ivr_menu`, `ivr_option`; context `from-trunk`, `ivr` |
| 5 | Máy lẻ AI (201) chuyển cuộc gọi sang group 600 | pbx-node: context `from-ai`, `allow_transfer` |
| — | Quản lý server, máy lẻ, group, thống kê qua API | repo `pbx-gateway` |
| — | Gọi điện trên trình duyệt | repo `pbx-softphone-sdk` (máy lẻ 15x) |

--- | --- | --- |
| 4 | Menu IVR bấm phím (DTMF), số gọi vào (DID); máy 9000 giả làm nhà mạng | Bảng `did_routes`, `ivr_menu`, `ivr_option`; `func_odbc.conf`; context `from-trunk`, `ivr` |
| 5 | Máy lẻ AI (201) chuyển cuộc gọi sang group 600 | Context `from-ai`, `allow_transfer` |
| 6 | AMI: xem trạng thái, nghe sự kiện bấm phím | `manager.conf` |
| 7 | pbx-agent (Spring Boot) tự động hóa bước 3–6 qua REST API | Service `agent` trong `docker-compose.yml` |

---

> **Ghi chú:** mật khẩu trong project chỉ dùng cho lab. Khi triển khai thật: đổi toàn bộ mật khẩu, chỉ mở 5432/5038/8088 cho IP Gateway (không mở ra Internet), và giới hạn IP được vào cổng 5060.
