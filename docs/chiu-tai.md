# Chịu tải nhiều cuộc gọi đồng thời — các thay đổi (21/10/2026)

Tài liệu này ghi lại **mỗi thay đổi sửa vấn đề gì, sửa ra sao, cách kiểm tra**. Đọc theo thứ tự mục 1 → 7.
Tóm tắt nhanh: không đổi kiến trúc, không đổi quyết định nào trong CLAUDE.md mục 2; chỉ sửa cấu hình vận hành
và thêm công cụ thử tải. Mọi biến mới đều có giá trị mặc định → `.env` đang dùng **không bắt buộc** phải sửa.

| # | Vấn đề | File đổi | Mặc định sau khi sửa |
| --- | --- | --- | --- |
| 1 | Dải cổng RTP quyết định số cuộc tối đa, ghi chú cũ tính sai | `.env.example`, `.env.cloud.example`, `asterisk/entrypoint.sh` | In sức chứa khi khởi động |
| 2 | Giới hạn file mở (ulimit) thấp → "Too many open files" | `docker-compose.yml`, `asterisk/entrypoint.sh` | 65536 + cảnh báo nếu thấp |
| 3 | Log Docker và log Asterisk phình mãi | `docker-compose.yml`, `docker-compose.cloud.yml`, `asterisk/entrypoint.sh` | Docker 5×20 MB; Asterisk xoay vòng hằng ngày, giữ 14 ngày |
| 4 | Ghi âm làm đầy ổ, kéo DB/astdb/log hỏng theo | `docker-compose.yml`, `asterisk/entrypoint.sh` | Cảnh báo ở 85 %; KHÔNG tự xóa ghi âm |
| 5 | Sự kiện AMI RTCP có thể tràn kết nối AMI (phòng hờ) | `asterisk/conf/manager.conf.tmpl` | Bỏ `RTCPSent`/`RTCPReceived` |
| 6 | Mức log `-vvv` quá chi tiết khi tải cao | `asterisk/entrypoint.sh` | `AST_VERBOSE=3` (như cũ), thật nên 0–1 |
| 7 | Chưa có cách đo sức chịu tải | `asterisk/conf/extensions.conf` (`*45`), `scripts/load-test.sh`, `scripts/load-test/uac-auth.xml` | — |

---

## 1. Dải cổng RTP = trần số cuộc gọi

**Vấn đề.** Mỗi kênh (một "chân" cuộc gọi) giữ 2 cổng UDP: RTP (âm thanh) + RTCP (thống kê). Cuộc gọi 2 bên = 2 kênh = 4 cổng.
Gọi group `ringall`: mỗi thành viên đang đổ chuông cũng là 1 kênh. Hết cổng → cuộc mới lỗi hoặc mất tiếng.

| Dải | Cổng | Kênh | Cuộc gọi 2 bên |
| --- | --- | --- | --- |
| Lab `10000–10099` | 100 | ~50 | **~25** (ghi chú cũ ghi 50 — sai) |
| Cloud `10000–20000` | 10001 | ~5000 | ~2500 (ghi chú cũ ghi 5000 — sai). Dư so với CPU, không còn là giới hạn |

**Đã sửa.**
- Sửa lại ghi chú trong `.env.example`, `.env.cloud.example`.
- `entrypoint.sh` in ra lúc khởi động (xem bằng `docker compose logs asterisk | grep "Dải RTP"`):
  `Dải RTP 10000-10099: 100 cổng ≈ 50 kênh ≈ 25 cuộc gọi 2 bên cùng lúc ...`

**Không đổi dải của lab.** Lab chạy Docker bridge: Docker map từng cổng một (mỗi cổng một tiến trình docker-proxy),
mở hàng nghìn cổng làm khởi động rất chậm. Lab chỉ để thử chức năng. Thử tải và chạy thật dùng `docker-compose.cloud.yml`
(`network_mode: host`, không map cổng). Nếu lab chạy trên Linux và cần thử ~100 cuộc, có thể nới tới `10000–10499`.

## 2. Giới hạn file mở (ulimit nofile)

**Vấn đề.** Mỗi kênh mở nhiều file/socket: 2 socket RTP/RTCP, file ghi âm, timer, kết nối TCP/TLS/WSS…
Tùy cấu hình Docker daemon, giới hạn mặc định có thể chỉ 1024 → khoảng 100–200 cuộc là Asterisk báo
`Too many open files`, cuộc mới hỏng, có thể kéo theo lỗi lạ khác (không mở được file ghi âm, không nhận kết nối AMI).

**Đã sửa.** `docker-compose.yml`, service `asterisk`:
```yaml
ulimits:
  nofile:
    soft: 65536
    hard: 65536
```
Bản cloud chồng lên file gốc nên tự có. `entrypoint.sh` kiểm tra lúc khởi động, thấp hơn 65536 thì in
`CẢNH BÁO: giới hạn file mở (ulimit -n) chỉ ...`.

**Kiểm tra.** `docker compose exec asterisk sh -c 'ulimit -n'` → `65536`.

## 3. Log không giới hạn dung lượng

**Vấn đề.** (a) Docker giữ toàn bộ stdout của container (`docker logs`) mãi mãi; Asterisk chạy `-vvv` ghi hàng chục dòng mỗi
cuộc gọi → ổ đầy dần. (b) `/var/log/asterisk` (`messages.log`, `security.log`, `queue_log`) không bao giờ xoay vòng.

**Đã sửa.**
- `docker-compose.yml` và `docker-compose.cloud.yml`: khối dùng chung `x-logging` (json-file, `max-size: 20m`, `max-file: 5`)
  gắn vào mọi service → mỗi service tối đa ~100 MB log Docker, cũ tự xóa.
- `entrypoint.sh`:
  - Đặt `rotatestrategy = timestamp` trong `logger.conf`: khi xoay vòng, file cũ đổi tên thành `<tên>.<số giây epoch>`, Asterisk mở file mới.
  - Tiến trình dọn dẹp chạy nền (mục 4) mỗi ngày một lần chạy `asterisk -rx "logger rotate"`, rồi xóa file trong
    `/var/log/asterisk` cũ hơn `LOG_KEEP_DAYS` ngày (mặc định 14). Không xóa file `queue_log` đang ghi.
  - fail2ban vẫn đọc được `security.log` sau khi xoay vòng (fail2ban tự phát hiện file mới).

## 4. Ghi âm làm đầy ổ

**Vấn đề.** Mọi cuộc gọi đều ghi âm, ~1 MB/phút/cuộc: 100 cuộc đồng thời ≈ 6 GB/giờ. File không tự xóa (quyết định đã chốt)
và nằm chung ổ với PostgreSQL, astdb, log → ổ đầy là hỏng cả cụm, không chỉ mất ghi âm.

**Đã sửa (không đổi quyết định "không tự xóa").**
- **Tách ổ:** `docker-compose.yml` gắn ghi âm bằng `${RECORDINGS_PATH:-recordings}:/var/spool/asterisk/recording`.
  Không đặt gì = volume `recordings` như cũ. Đặt `RECORDINGS_PATH=/data/recordings` (thư mục trên ổ riêng) thì ghi âm ra đó.
  `.env.cloud.example` để sẵn `/data/recordings`. Đổi đường dẫn khi đang chạy: chép file cũ từ volume sang trước, rồi `up -d`.
- **Cảnh báo đầy ổ:** tiến trình dọn dẹp kiểm tra lúc khởi động và mỗi giờ; ổ chứa ghi âm / log / astdb dùng
  từ `DISK_WARN_PERCENT` % (mặc định 85) thì in ra `docker logs`:
  `[don-dep] CẢNH BÁO: ổ chứa /var/spool/asterisk/recording đã dùng 91% (ngưỡng 85%)`.
  Hệ thống giám sát (hoặc Gateway) nên bắt dòng này.
- **Tùy chọn xóa theo thời hạn:** chỉ khi đặt `RECORDING_KEEP_DAYS=N` mới xóa file `.wav` cũ hơn N ngày. Mặc định để trống =
  không bao giờ xóa. Lưu ý: dòng `cdr`/lịch sử ở Gateway vẫn giữ tên file → Gateway tải sẽ nhận 404, cần xử lý hiển thị.

Tiến trình dọn dẹp là hàm `housekeeping` trong `entrypoint.sh`, chạy nền ngay trước khi `exec asterisk`,
nên là tiến trình con của Asterisk và dừng cùng container.

## 5. Sự kiện AMI tràn kết nối Gateway (phòng hờ)

> **Đính chính (21/10/2026, sau khi đọc code pbx-gateway):** Gateway đăng nhập AMI với `Events: cdr,system`
> (`GW_AMI_EVENTS`, mặc định) nên **hiện tại không nhận RTCP** — vấn đề dưới đây chỉ xảy ra khi đặt `GW_AMI_EVENTS=on`
> hoặc có client AMI khác dùng cùng tài khoản. Bộ lọc giữ lại như lớp bảo vệ thứ hai, không phải sửa lỗi đang có.

**Vấn đề (nếu nhận mọi sự kiện).** Tài khoản AMI của Gateway có quyền đọc lớp `reporting`. Lớp này gồm `RTCPSent`/`RTCPReceived`: Asterisk gửi vài giây
một lần cho **mỗi** kênh có âm thanh → 200 cuộc ≈ hàng trăm sự kiện/giây mà Gateway không dùng. Nếu Gateway đọc không kịp quá
`writetimeout = 5000` ms, Asterisk ngắt kết nối AMI → các sự kiện `Cdr` trong lúc mất kết nối bị mất (lịch sử thiếu cuộc gọi).

**Đã sửa.** `manager.conf.tmpl`, user Gateway:
```
eventfilter = !Event: RTCP
```
`!` = loại trừ. Khi chỉ có bộ lọc loại trừ, mọi sự kiện khác (`Cdr`, `Newchannel`, `Hangup`, `QueueMember*`, `DTMF*`...) vẫn
gửi như cũ. Kết quả lệnh (`QueueStatus`, `GetConfig`...) không bị ảnh hưởng.

**Cần xác nhận phía `pbx-gateway`:** Gateway không đọc sự kiện `RTCPSent`/`RTCPReceived` (dự kiến là không). Cần xem chất lượng
âm thanh thì dùng `asterisk -rx "pjsip show channelstats"`.

## 6. Mức log của Asterisk

**Vấn đề.** `asterisk -f -vvv` in mọi bước dialplan ra màn hình (= `docker logs`). Vừa tốn CPU/ổ khi tải cao, vừa khó tìm lỗi thật.

**Đã sửa.** `entrypoint.sh` đọc `AST_VERBOSE` (0–5), mặc định **3 = như cũ** để lab gỡ lỗi được.
`.env.cloud.example` đặt `AST_VERBOSE=1`. Lỗi/cảnh báo (`NOTICE`, `WARNING`, `ERROR`) vẫn luôn được ghi, không phụ thuộc mức này.
Cần xem chi tiết tạm thời mà không restart: `docker compose exec asterisk asterisk -rx "core set verbose 3"`.

## 7. Thử tải bằng SIPp

**Thành phần.**
- `extensions.conf`, số **`*45`** (đích thử tải): nhấc máy → ghi âm (MixMonitor, không có tùy chọn `b` vì không có bên thứ hai)
  → phát nhạc chờ tới khi bên gọi gác máy. Khi gác máy, `[sub-loadtest-end]` xóa file ghi âm thử → thử tải không làm đầy ổ.
  Tự cúp sau 10 phút. `RECORD_CALLS=no` thì không ghi âm (giống cuộc gọi thật).
- `scripts/load-test/uac-auth.xml`: kịch bản SIPp — INVITE, trả lời thử thách mật khẩu 401, giữ máy, BYE.
  SIPp chạy `-rtp_echo` phát lại âm thanh nhận được → RTP 2 chiều.
- `scripts/load-test.sh`: tạo máy lẻ thử `599` qua ARI (mật khẩu ngẫu nhiên, md5 như máy thật), chạy SIPp, xong (hoặc Ctrl+C)
  tự xóa máy lẻ thử. Từ chối chạy nếu số `599` đã có người dùng (đổi bằng `LOADTEST_EXT=...`).

**Quy đổi.** 1 cuộc thử = 1 kênh. Cuộc gọi thật 2 bên = 2 kênh → **N cuộc thử ≈ N/2 cuộc gọi thật** về RTP và ghi âm.
Nhạc chờ là file WAV nên Asterisk phải chuyển mã thêm (cuộc gọi thật không cần) → kết quả hơi bi quan, tức là an toàn.

**Cách chạy** (trên một máy Linux khác, cùng mạng nội bộ; cần `sudo apt install sip-tester curl`):
```bash
# ./scripts/load-test.sh <IP SIP của tổng đài> <cuộc đồng thời> [giây mỗi cuộc=60] [cuộc mới/giây=5] [.env]
ARI_HOST=10.0.1.5 ./scripts/load-test.sh 10.0.1.5 100 60 10 .env
# tăng dần 100 -> 200 -> 400... tới khi có cuộc lỗi, mất gói, hoặc CPU > ~70 %
```
Trong lúc chạy, trên máy tổng đài:
```bash
docker compose exec asterisk asterisk -rx "core show channels count"   # số kênh đang có
docker stats pbx-asterisk                                              # CPU, RAM
docker compose exec asterisk asterisk -rx "pjsip show channelstats"    # cột Lost / Jitter: mất gói, rung
docker compose logs --since 5m asterisk | grep -E "WARNING|ERROR"      # chú ý: taskprocessor, Too many open files
```
Kết quả SIPp: dòng `Successful call` / `Failed call` cuối màn hình và file `loadtest-<thời điểm>.csv`.
Ngưỡng nên ghi lại cho từng cấu hình máy: số kênh tối đa mà Failed = 0, mất gói ≈ 0 % và CPU còn dư ≥ 30 %.

**Đã thử (21/10/2026)** — Asterisk 20.6 (đúng gói Ubuntu 24.04 của image), máy thử 2 vCPU, SIPp chạy CÙNG máy, ghi âm bật:
- 20 cuộc đồng thời, 40 cuộc: thành công 40/40; RTP nhận/gửi đều, mất 0 gói; file ghi âm thử tạo ra rồi tự xóa hết.
- **200 cuộc đồng thời (≈ 100 cuộc gọi thật)**, 400 cuộc: thành công 400/400, mất 0 gói, Asterisk dùng ~0,9 core.
- Đây chỉ là con số định hướng (không phải máy thật của dự án, SIPp tranh CPU với Asterisk). Phải đo lại trên máy chủ thật.

---

## Những gì CHƯA sửa (và lý do)

| Mục | Lý do |
| --- | --- |
| CDR `batch` (`cdr.conf`) | Gom CDR làm sự kiện AMI `Cdr` tới Gateway chậm và dồn cục, crash mất cả lô. PostgreSQL ghi vài trăm dòng/giây dễ dàng → chưa cần. Xem lại nếu thử tải thấy log CDR chậm |
| `unanswered = yes` (nhiều dòng CDR mỗi cuộc gọi group) | Là yêu cầu lịch sử, không phải lỗi tải |
| `System(rm -f ...)` khi gác máy | Mỗi lần tạo một tiến trình shell, tốn rất ít; Asterisk không có lệnh xóa file sẵn |
| Luồng nhà mạng → IVR (`from-trunk`, trunk) | Là chức năng mới, cần thông tin nhà mạng/Media AI. Khi làm: mỗi cuộc ≥ 2 kênh (trunk + AI), lúc chuyển sang người thật 3–4 kênh → đo lại bằng thử tải |
| Nhiều node / SBC / dự phòng | Thay đổi kiến trúc, cần quyết định riêng |
| Dải RTP lab | Xem mục 1 |

## Áp dụng lên cụm đang chạy

```bash
git pull
# (tùy chọn) thêm vào .env: AST_VERBOSE, LOG_KEEP_DAYS, DISK_WARN_PERCENT, RECORDINGS_PATH, RECORDING_KEEP_DAYS — xem .env.example
docker compose up -d --build                  # bắt buộc --build: entrypoint.sh nằm trong image
# cloud: docker compose -f docker-compose.yml -f docker-compose.cloud.yml up -d --build
docker compose logs asterisk | grep -E "Dải RTP|CẢNH BÁO"
docker compose exec asterisk sh -c 'ulimit -n'                                  # 65536
docker compose exec asterisk grep -n eventfilter /etc/asterisk/manager.conf
```
Lưu ý: `up -d --build` khởi động lại Asterisk → **rớt các cuộc gọi đang diễn ra**, làm ngoài giờ.
