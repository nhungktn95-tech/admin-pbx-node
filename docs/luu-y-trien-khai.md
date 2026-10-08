# Lưu ý triển khai pbx-node (checklist)

Tổng hợp từ các lỗi đã gặp khi triển khai thật trên Ubuntu. Đọc hết trước mỗi lần cài mới hoặc chuyển máy.
Mỗi mục ghi: **làm gì** → *nếu quên thì bị gì*.

---

## 1. Máy chủ

- [ ] Ubuntu Server 24.04, **IP tĩnh** (netplan hoặc giữ IP trên router).
  → *IP đổi thì phải sửa `HOST_IP` và tạo lại chứng chỉ WSS (mục 3).*
- [ ] Máy ảo: card mạng **Bridged**, không dùng NAT.
  → *Softphone không đăng nhập được hoặc không có tiếng.*
- [ ] Cài Docker Engine + compose plugin, `sudo systemctl enable --now docker`.
- [ ] Thêm user vào nhóm docker: `sudo usermod -aG docker $USER` rồi đăng xuất/đăng nhập lại (hoặc `newgrp docker`).
  → *`permission denied ... /var/run/docker.sock`.*
- [ ] **Không** chạy deploy bằng `sudo`.
  → *File trong project thành của root, lần sau WinSCP/scp không ghi đè được.*
- [ ] Múi giờ: `sudo timedatectl set-timezone Asia/Ho_Chi_Minh`.

## 2. Chép code từ Windows sang

Windows không giữ quyền Linux (rwx) và dễ sinh CRLF. Hai lỗi đã gặp:
`ls: cannot open directory '/docker-entrypoint-initdb.d/': Permission denied` (DB unhealthy) và giá trị `.env` dính `\r`.

- [ ] **Không chép `.env`** từ Windows (sai `HOST_IP`, có thể CRLF). `.env` tạo một lần trên máy chủ.
- [ ] Cách chép:
  - **tar + scp** (ổn định nhất), chạy trên Windows:
    ```powershell
    cd D:\project\admin
    tar -czf pbx-node.tgz --exclude=.env --exclude=.vscode pbx-node
    scp pbx-node.tgz <user>@<IP>:~/project/
    ssh <user>@<IP> "cd ~/project && tar -xzf pbx-node.tgz && rm pbx-node.tgz"
    ```
  - **WinSCP**: *Preferences → Transfer → Default*: Transfer mode = **Binary**, **bỏ tích** Set permissions, **File mask để trống**. Bỏ chọn `.env` khi kéo.
    → *File mask sai = chỉ tạo thư mục, không có file nào sang. Set permissions thiếu "Add X to directories" = thư mục không vào được.*
- [ ] **Sau mỗi lần chép**, luôn chạy: `bash scripts/deploy.sh` (sửa quyền 755/644, bỏ CRLF, cảnh báo sai `HOST_IP`, build + chạy).
  Gọi bằng `bash ...`, không phụ thuộc bit +x.
- [ ] Editor trên Windows lưu LF: repo đã có `.editorconfig`, `.vscode/settings.json`, `.gitattributes`. Góc phải dưới VS Code phải là `LF`.

## 3. File `.env` trên máy chủ

| Biến | Đúng | Nếu sai |
| --- | --- | --- |
| `HOST_IP` | IP LAN của **chính máy chủ** (`hostname -I`) | Cuộc gọi tự ngắt sau **32 giây**, không có tiếng, chứng chỉ WSS sai IP |
| `GATEWAY_IP` | IP máy chạy PBX Gateway (cùng máy thì = `HOST_IP`) | Gateway không đăng nhập được AMI |
| `AMI_PERMIT_EXTRA` | Lab cùng máy: `172.16.0.0/255.240.0.0`. Thật: `<IP Gateway>/255.255.255.255` | Mở AMI rộng hơn cần thiết |
| Mật khẩu (`DB_PASSWORD`, `AMI_SECRET`, `ARI_PASSWORD`, `GW_DB_PASSWORD`) | `openssl rand -hex 16`, khác bản lab | Lộ quyền quản trị |

- [ ] Đổi `HOST_IP` sau khi đã chạy → **xóa chứng chỉ cũ** (chứng chỉ chỉ tạo ở lần chạy đầu, nằm trong volume `astkeys`):
  ```bash
  docker compose exec asterisk sh -c 'rm -f /etc/asterisk/keys/asterisk.*'
  docker compose up -d --force-recreate asterisk
  ```
  Kiểm tra từ máy khác: `openssl s_client -connect <IP>:8089 </dev/null | openssl x509 -noout -subject` phải ra `CN=<HOST_IP>`.
- [ ] Sửa `.env` xong dùng `docker compose up -d` (tạo lại container). `restart` **không** đọc lại `.env`.

## 4. Firewall

- [ ] UFW cho cổng thoại:
  ```bash
  sudo ufw allow OpenSSH
  sudo ufw allow 5060/udp
  sudo ufw allow 10000:10099/udp      # khớp RTP_START–RTP_END
  sudo ufw allow 8089/tcp
  sudo ufw enable
  ```
- [ ] **Docker bỏ qua UFW** với cổng publish → 5432 / 5038 / 8088 phải chặn ở chain `DOCKER-USER`, chỉ cho IP Gateway (+ máy quản trị):
  ```bash
  IFACE=<card mạng>; GW=<IP Gateway>
  for p in 5432 5038 8088; do
    sudo iptables -I DOCKER-USER -i $IFACE -p tcp --dport $p -j DROP
    sudo iptables -I DOCKER-USER -i $IFACE -p tcp --dport $p -s $GW -j ACCEPT
  done
  sudo apt install -y iptables-persistent && sudo netfilter-persistent save
  ```
  → *Không làm thì DB, AMI, ARI mở cho cả mạng LAN (Postgres cho mọi IP đăng nhập bằng mật khẩu).*
- [ ] Không bao giờ mở 5038 (AMI, không mã hóa) ra Internet.

## 5. Database

- [ ] Script `db/init/*` **chỉ chạy lần đầu** (volume `pgdata` trống). Sửa seed/schema sau đó:
  - dữ liệu thử: `docker compose down -v && bash scripts/deploy.sh` (**xóa sạch DB**);
  - DB đang dùng: viết file `sql/*.sql` và chạy tay `docker compose exec -T db psql -U asterisk -d asterisk < sql/<file>.sql`.
- [ ] DB dùng image riêng `db/Dockerfile` (postgres:16 + **tzdata-legacy**).
  → *Thiếu gói: DBeaver/Gateway (Java trên Windows) lỗi `invalid value for parameter "TimeZone": "Asia/Saigon"`.*
- [ ] Mật khẩu máy lẻ **không lưu dạng gốc**: `auth_type='md5'`, `realm='asterisk'`, `md5_cred=md5('<user>:asterisk:<mật khẩu>')`, `password` = NULL (DB từ chối nếu ghi mật khẩu gốc).
  DB cũ còn mật khẩu gốc: chạy `sql/bao-mat-mat-khau-md5.sql`.
- [ ] **Không đổi `default_realm`** trong `pjsip.conf` — đổi là mọi `md5_cred` phải tính lại.
- [ ] Nhập mật khẩu: **trim khoảng trắng**. Đã gặp: dán `lab101pass␣` → `Failed to authenticate` (log chỉ thấy 401, DB không nhìn ra vì đã băm).
- [ ] DBeaver: Host = **IP máy chủ** (không phải `localhost` — đó là Postgres trên máy Windows), Database = `asterisk`.
- [ ] Thêm cột vào `cdr` (ví dụ `recordingfile`) xong phải `docker compose restart asterisk`: `cdr_adaptive_odbc` chỉ đọc danh sách cột lúc khởi động.
  → *Thiếu bước này: cột mới luôn trống, log không báo lỗi.*

### Ghi âm cuộc gọi

- [ ] File ghi âm nằm trong volume `recordings` và **không tự xóa** (WAV ~1 MB/phút). Theo dõi `df -h`; cần thì Gateway xóa qua ARI `DELETE /ari/recordings/stored/<tên>`.
- [ ] `docker compose down -v` **xóa luôn toàn bộ ghi âm**. Sao lưu trước: `docker compose cp asterisk:/var/spool/asterisk/recording ./backup-ghi-am`.
- [ ] Asterisk lấy múi giờ từ `/etc/localtime`, **không** từ biến `TZ` → `entrypoint.sh` tạo link theo `TZ`.
  → *Thiếu: `cdr.calldate` và tên file ghi âm lệch 7 tiếng (giờ UTC).*
- [ ] Ghi âm cuộc gọi của người dân: phải có lời thông báo "cuộc gọi được ghi âm" khi làm IVR (bước 4).

## 6. Asterisk trong Docker (NAT)

Hai lỗi âm thanh đã gặp, cả hai do Asterisk nằm trong mạng Docker `172.x`:

| Cấu hình (đã có trong repo, **đừng xóa**) | Nếu thiếu |
| --- | --- |
| `pjsip.conf`: `local_net = ${CONTAINER_IP}/32` (cạnh `127.0.0.1/32`) ở cả `transport-udp` và `transport-wss` | SDP gửi softphone là `c=IN IP4 172.18.x.x` → Linphone/MicroSIP **không có tiếng** (Receive = 0) |
| `rtp.conf`: `[ice_host_candidates]` `${CONTAINER_IP} => ${HOST_IP}` | Trình duyệt trên máy có card ảo (Docker Desktop, WSL, VirtualBox) **không gửi được tiếng** |
| `external_media_address` / `external_signaling_address` = `${HOST_IP}` | Cuộc gọi ngắt sau 32 giây, không tiếng |

- [ ] **Không** thêm dải LAN (`192.168.x`) vào `local_net`.
- [ ] **Không** dùng cả dải Docker `172.16.0.0/12` trong `local_net` (bản cũ từng dùng): dải này chứa cổng mạng Docker `172.x.0.1`,
  là IP nguồn của softphone chạy cùng máy với Docker, và của mọi softphone khi dùng Docker Desktop (Windows/macOS).
  → *`200 OK` gửi `Contact: <sip:172.x.0.3:5060>`, `c=IN IP4 172.x.0.3` → softphone không gửi được ACK → **cuộc gọi ngắt ở giây 32**.
  Kiểm tra: `pjsip set logger on`, xem `Contact` và `c=` trong `200 OK` phải là `HOST_IP`.*
- [ ] Softphone chạy **cùng máy** với Asterisk Docker: không được dùng cổng SIP 5060 (Docker đã giữ). Linphone 6: đặt `sip_port=5070`
  trong `%LOCALAPPDATA%\linphone\linphonerc` (khóa `sip_udp_port` không có tác dụng; chỉ sửa khi Linphone đã Quit).
  → *Linphone báo `Error during connection`, log Asterisk trống; log Linphone: `udp bind() failed ... port 5060`.*
- [ ] Sửa transport PJSIP phải **restart container**, `reload` không đủ.

## 7. Máy web (WebRTC: máy lẻ `webrtc=yes`, số 100–599 như người dùng thường)

- [ ] Ô WSS là **`wss://<IP>:8089/ws`**, không phải `https://...` (lỗi `Invalid scheme in WebSocket Server URL`).
- [ ] Dùng máy lẻ **150/151** (`webrtc=yes`), không dùng 101/102 (máy UDP, thiếu DTLS/ICE).
- [ ] **Mỗi thiết bị, mỗi trình duyệt** phải tin chứng chỉ tự ký:
  mở `https://<IP>:8089/ws` → Advanced → Proceed (thấy `Upgrade Required` là được). Chrome quên khi tắt trình duyệt.
  → *Log Asterisk: `ast_iostream_start_tls: Problem setting up ssl connection ... Internal SSL error` từ IP thiết bị đó.*
  Lâu dài: cài chứng chỉ vào máy (Windows: `certutil -addstore Root <file>.crt`; Android: Cài đặt → Bảo mật → Cài chứng chỉ CA; iPhone: cài hồ sơ + bật *Certificate Trust Settings*).
- [ ] Trình duyệt **chỉ cho dùng micro khi trang softphone mở bằng HTTPS** (hoặc `localhost`). Điện thoại mở `http://192.168.x.x` → đăng ký được nhưng không gửi tiếng.
- [ ] Môi trường thật: dùng chứng chỉ thật theo tên miền, không dùng tự ký.
- [ ] Container Asterisk phải có **hostname cố định bắt đầu bằng chữ cái** (`hostname: pbx-asterisk` trong `docker-compose.yml`).
  Asterisk dùng hostname làm tên miền trong `From`/`Contact` khi gửi qua WebSocket; hostname mặc định của Docker là mã container
  ngẫu nhiên, nếu bắt đầu bằng chữ số (vd `480a5ff399f6`) thì sai chuẩn SIP và JsSIP bỏ gói. Lỗi lúc có lúc không, tùy lần tạo container.
  → *Máy web đăng ký được nhưng `pjsip show contacts` là `Unavail`; gọi tới máy web: `Could not create dialog to invalid URI '150'`.
  Console trình duyệt (`JsSIP.debug.enable('JsSIP:*')`): `error parsing "From" header field`.*

## 8. Sửa file nào → chạy lệnh gì

| Đã sửa | Lệnh |
| --- | --- |
| Bất kỳ (sau khi chép) | `bash scripts/deploy.sh` |
| `asterisk/Dockerfile`, `entrypoint.sh`, `db/Dockerfile` | `bash scripts/deploy.sh` (có `--build`) |
| `asterisk/conf/*` | `docker compose restart asterisk` |
| Chỉ `extensions.conf` (không rớt cuộc gọi) | `docker compose exec asterisk cp /opt/pbx-conf/extensions.conf /etc/asterisk/` rồi `asterisk -rx "dialplan reload"` |
| `.env`, `docker-compose.yml` | `docker compose up -d` |
| `db/init/*` | `down -v` (mất dữ liệu) hoặc chạy SQL tay |
| Máy lẻ / group trong DB | Không cần gì (Realtime) |
| `sql/*`, `scripts/*`, tài liệu | Không cần gì |

## 9. Kiểm tra sau khi triển khai

```bash
docker compose ps                                                   # pbx-db healthy, pbx-asterisk running
docker compose logs db | grep -iE "error|Đã tạo"                    # có "Đã tạo/cập nhật user DB cho Gateway"
docker compose exec asterisk asterisk -rx "odbc show"               # active connections: 1
docker compose exec asterisk asterisk -rx "pjsip show endpoints"    # 101 102 150 151 201
docker compose exec asterisk asterisk -rx "pjsip show transport transport-udp" | grep -E "external|local_net"
docker compose exec asterisk grep -A1 ice_host_candidates /etc/asterisk/rtp.conf   # 172.x => HOST_IP
./scripts/check-gateway-access.sh <HOST_IP> .env                    # từ máy Gateway: toàn OK
```

Thử gọi theo thứ tự: `*43` (nghe lại tiếng mình) → `*44` (bấm số + `#`, nghe đọc lại = DTMF chạy) → 101↔102 (nói **quá 32 giây**) → gọi 600 → web 150↔softphone 101 → web↔web (máy tính ↔ điện thoại).

### Không có tiếng: đọc `pjsip show channelstats` trong lúc gọi

| Receive của máy X | Nghĩa | Xem mục |
| --- | --- | --- |
| Tăng | Tiếng từ X tới Asterisk tốt | — |
| **0**, X là softphone | SDP sai địa chỉ (`c=IN IP4 172.x`), firewall UDP 10000–10099, Windows Firewall chặn softphone | 3, 4, 6 |
| **0**, X là trình duyệt | Micro (trang không HTTPS), ICE chọn nhầm card mạng, DTLS | 6, 7 |
| Cả hai máy Receive tăng mà vẫn không nghe | Loa/micro thiết bị, trình duyệt tắt tiếng | — |

Công cụ: `pjsip set logger on` (xem SIP/SDP), `rtp set debug ip <IP>` (xem từng gói), `sudo tcpdump -ni any udp portrange 10000-10099`, `chrome://webrtc-internals` (trên trình duyệt).

## 10. Việc bảo mật còn mở

- AMI của Gateway có quyền ghi `system` + `originate` → có thể chạy lệnh shell trong container qua `Originate`. Đề xuất bỏ `system` (chờ chốt).
- ARI (`/ari`) truy cập được cả qua 8089 (cổng mở cho người dùng) → đặt `ARI_PASSWORD` mạnh; lâu dài đặt nginx/SBC trước 8089, chỉ chuyển `/ws`.
- `/httpstatus` công khai → đề xuất `enable_status = no` trong `http.conf`.
- Xóa hoặc đổi mật khẩu các máy lẻ mẫu (`labXXXpass`) trước khi cho người dùng thật vào.
