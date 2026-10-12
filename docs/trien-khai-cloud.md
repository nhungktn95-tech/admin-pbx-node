# Triển khai pbx-node trên cloud

Dùng `docker-compose.yml` + `docker-compose.cloud.yml` + `.env` theo mẫu `.env.cloud.example`.
Bản lab (LAN) không đổi: vẫn chỉ `docker compose up -d --build`.

## 1. `docker-compose.cloud.yml` xử lý gì

| Vấn đề | Cách xử lý | Thành phần |
| --- | --- | --- |
| SIP 5060 bị bot dò mật khẩu, gọi trộm cước | Asterisk ghi `security.log`; fail2ban chặn IP sai 5 lần/10 phút (1 giờ, tái phạm tăng dần tới 1 tuần) | `fail2ban`, `cloud/fail2ban/jail.d/asterisk.local` |
| AMI 5038 / ARI 8088 không mã hóa | Asterisk chỉ nghe trên `ADMIN_BIND` (IP nội bộ/VPN), không nghe IP public | `manager.conf.tmpl`, `http.conf.tmpl` (`AST_ADMIN_BIND`) |
| ARI lộ qua cổng WSS 8089 | Asterisk WSS chỉ nghe `127.0.0.1:8089`; nginx nhận `wss://DOMAIN/ws` ở 443 và **chỉ** chuyển tiếp `/ws` (giới hạn kết nối mỗi IP) | `nginx`, `cloud/nginx/templates/default.conf.template` |
| Chứng chỉ tự ký | Let's Encrypt, tự gia hạn (certbot 12 giờ/lần, nginx nạp lại 6 giờ/lần) | `certbot`, `nginx` |
| IP public khác IP card mạng (NAT 1:1 của cloud) | `HOST_IP` = IP public (SDP, ICE); `PRIVATE_IP` = IP card mạng (`local_net`, ICE candidate gốc) | `entrypoint.sh` (`LOCAL_IP`) |
| Docker map dải RTP lớn rất chậm | Asterisk chạy `network_mode: host`, dải RTP rộng (mặc định mẫu 10000–20000) | `asterisk` |
| Trình duyệt ở mạng chặn UDP | TURN (coturn), bật khi cần: `--profile turn` | `coturn` |
| Database | Chỉ nghe `127.0.0.1:5432` trong máy chủ | `db` |

**Không tự làm được bằng compose** (làm tay theo mục 3, 6): firewall/Security Group, VPN cho Gateway, tên miền, sao lưu, giám sát.

## 2. Chuẩn bị

1. Máy ảo Ubuntu 24.04, Docker Engine + Compose plugin, có IP public (IP tĩnh/Elastic IP).
2. **Hostname máy chủ bắt đầu bằng chữ cái** (`hostnamectl`; vd `pbx-01`, `ip-10-0-1-5`). Chế độ host dùng hostname máy chủ
   làm tên miền trong SIP qua WebSocket; bắt đầu bằng chữ số → máy web không nhận được cuộc gọi (xem `luu-y-trien-khai.md` mục 7).
3. Tên miền: bản ghi A `DOMAIN` → `HOST_IP`. Kiểm tra: `dig +short <DOMAIN>`.
4. Mạng riêng cho Gateway: Gateway cùng VPC (dùng IP nội bộ) hoặc VPN (WireGuard). `ADMIN_BIND` = IP của máy chủ trong mạng đó.
5. `.env`:
   ```bash
   cp .env.cloud.example .env && nano .env      # sửa mọi dòng có (*)
   ```

## 3. Firewall

Mở **đúng** các cổng sau ở Security Group của cloud **và** `ufw` trên máy:

| Cổng | Cho ai |
| --- | --- |
| 22/tcp | Quản trị (nên giới hạn IP văn phòng) |
| 80/tcp, 443/tcp | Mọi người (Let's Encrypt, WSS cho trình duyệt) |
| 5060/udp, 5060/tcp | Softphone, nhà mạng (giới hạn IP nhà mạng nếu được) |
| 5061/tcp | Softphone dùng SIP TLS (nên dùng thay UDP/TCP khi qua Internet: mã hóa mật khẩu, số gọi) |
| `RTP_START`–`RTP_END`/udp | Âm thanh |
| 3478/udp+tcp, `TURN_MIN_PORT`–`TURN_MAX_PORT`/udp | Chỉ khi bật TURN |
| 5038/tcp, 8088/tcp | **Chỉ IP Gateway**, trên mạng nội bộ/VPN |

```bash
sudo ufw default deny incoming && sudo ufw default allow outgoing
sudo ufw allow 22/tcp
sudo ufw allow 80,443/tcp
sudo ufw allow 5060/udp
sudo ufw allow 5060,5061/tcp
sudo ufw allow 10000:20000/udp                                   # = RTP_START:RTP_END
sudo ufw allow from <GATEWAY_IP> to <ADMIN_BIND> port 5038,8088 proto tcp
# Khi bật TURN: sudo ufw allow 3478 && sudo ufw allow 49160:49360/udp
sudo ufw enable
```
Asterisk/nginx/coturn/fail2ban chạy `network_mode: host` nên `ufw` áp dụng bình thường (Docker không vượt firewall như khi map cổng).
Cổng 5432 chỉ mở ở `127.0.0.1`, không cần rule.

## 4. Cấp chứng chỉ lần đầu (trước khi nginx chạy)

```bash
set -a; . ./.env; set +a
C="docker compose -f docker-compose.yml -f docker-compose.cloud.yml"
$C run --rm --entrypoint certbot certbot certonly --standalone \
   -d "$DOMAIN" -m "$LETSENCRYPT_EMAIL" --agree-tos -n
```
Cần cổng 80 trống và tên miền đã trỏ đúng. Các lần gia hạn sau container `certbot` tự làm qua nginx (webroot).

## 5. Khởi động và kiểm tra

```bash
$C up -d --build                       # thêm --profile turn nếu dùng TURN
$C ps                                  # db, asterisk, nginx, certbot, fail2ban (coturn) đều Up
```

| Kiểm tra | Lệnh | Mong đợi |
| --- | --- | --- |
| AMI/ARI chỉ ở IP nội bộ | `sudo ss -ltnp \| grep -E ':5038\|:8088'` | `ADMIN_BIND:5038`, `ADMIN_BIND:8088` (không phải `0.0.0.0`) |
| WSS chỉ ở localhost | `sudo ss -ltnp \| grep 8089` | `127.0.0.1:8089` |
| Cổng vào trình duyệt | `curl -i https://$DOMAIN/ws` | `426`/`400` (chứng chỉ hợp lệ, không cần `-k`) |
| ARI không lộ | `curl -i https://$DOMAIN/ari/asterisk/info` | `404` |
| IP trong SDP/ICE | `$C exec asterisk asterisk -rx "pjsip show transport transport-udp"` | `external_*` = IP public, `local_net` = `PRIVATE_IP/32` |
| fail2ban | `$C exec fail2ban fail2ban-client status asterisk` | jail đang chạy, có danh sách IP bị chặn |
| Gateway | từ máy Gateway: `./scripts/check-gateway-access.sh <ADMIN_BIND> .env` | AMI, ARI OK (mục WSS của script kiểm tra cổng 8089 nên sẽ LỖI — bình thường ở cloud, WSS đi qua `https://DOMAIN/ws`) |

Xem IP bị chặn / bỏ chặn: `fail2ban-client status asterisk`, `fail2ban-client set asterisk unbanip <IP>`.

## 6. Cấu hình phía client

- Softphone SDK: WSS = **`wss://<DOMAIN>/ws`** (không còn `:8089`), domain SIP = `HOST_IP` hoặc `DOMAIN`.
  Bật TURN thì truyền `iceServers: [{ urls: 'turn:<DOMAIN>:3478', username: TURN_USER, credential: TURN_PASSWORD }]`
  (cần bổ sung ở repo `pbx-softphone-sdk`).
- Softphone cài máy: server = `HOST_IP`/`DOMAIN`, UDP 5060.
- **Không** chạy `scripts/chuyen-may-le-sang-astdb.sh` trên cụm cloud mới: script chép máy lẻ mẫu (`labXXXpass`) từ seed.
  Tạo máy lẻ thật qua Gateway với mật khẩu mạnh. Xóa group mẫu 600 nếu không dùng.

## 7. Lưu ý / giới hạn

- `entrypoint.sh` nằm trong image: mọi lần đổi `entrypoint.sh` hoặc thêm biến template phải `up -d --build`.
- nginx chuyển WSS vào Asterisk từ `127.0.0.1`, nên Asterisk/fail2ban **không** thấy IP thật của máy web: dò mật khẩu qua WSS
  chỉ bị chặn bởi giới hạn kết nối của nginx (10 kết nối, 5 lần mở/giây mỗi IP). `127.0.0.1` nằm trong `ignoreip` của fail2ban — không xóa.
- Âm thanh softphone thường (UDP) chưa mã hóa (chưa có TLS/SRTP); chỉ máy web mã hóa.
- Chưa có (nhóm vàng): sao lưu volume `astdb`, `astconf`, `pgdata`, `recordings`; giám sát/cảnh báo; xoay vòng log; dự phòng nhiều cụm + SBC.
