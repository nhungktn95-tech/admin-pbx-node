# Phương án: quản lý group (queue) qua AMI khi máy lẻ dùng astdb + ARI

> Trạng thái: **phương án, chưa làm, chưa chạy thử**. Ngày viết: 06/10/2026. Nhánh: `feature/astdb-ari-queue-ami`.
> Bổ sung cho PA2 trong [phan-tich-luu-tru-may-le.md](phan-tich-luu-tru-may-le.md): PA2 không quản lý được queue (F8).

## 1. Mục tiêu

Asterisk tự giữ toàn bộ cấu hình, PBX Gateway **chỉ dùng AMI + ARI**, không chạm DB của cụm:

| Đối tượng | Lưu ở | Gateway quản lý qua |
| --- | --- | --- |
| Máy lẻ (endpoint/auth/aor) | astdb (`/var/lib/asterisk/astdb/astdb.sqlite3`) | ARI Push Configuration (đã làm ở G2) |
| Group: tạo/xóa, strategy, timeout, thành viên, **thứ tự đổ chuông** | `queues.conf` | AMI `UpdateConfig` + `QueueReload` |
| Lịch sử cuộc gọi | bảng `cdr` + sự kiện AMI `Cdr` | AMI (đã làm ở G2) |
| Ghi âm | `/var/spool/asterisk/recording` | ARI `/recordings/stored` |

Vẫn dùng `app_queue`, nên giữ đủ hàng chờ, nhạc chờ, tạm nghỉ (pause), `wrapuptime` và sự kiện AMI cho thống kê.

## 2. Cách làm (cách 1, khuyến nghị)

Group khai báo tĩnh trong `queues.conf`. Gateway sửa file qua AMI `UpdateConfig`, rồi `QueueReload`. `QueueReload` nạp lại mà **không rớt cuộc gọi đang chờ**.

```ini
[600]
strategy = linear            ; đổ lần lượt theo thứ tự dòng member
timeout = 15                 ; mỗi người 15 giây
retry = 2
ringinuse = no
member => PJSIP/102,0,Nhan vien 102,PJSIP/102    ; đổ trước
member => PJSIP/101,0,Nhan vien 101,PJSIP/101    ; đổ sau
```

| Việc | AMI |
| --- | --- |
| Xem group, thành viên | `GetConfig` (`Filename: queues.conf`) |
| Tạo group | `UpdateConfig`: `NewCat` + `Append` từng tham số |
| Sửa strategy/timeout... | `UpdateConfig`: `Update` |
| Thêm, bớt, đổi thứ tự thành viên | `UpdateConfig`: `Delete` các dòng `member` rồi `Append` lại theo thứ tự mới |
| Xóa group | `UpdateConfig`: `DelCat` |
| Áp dụng | `QueueReload` (Parameters + Members) |
| Trạng thái thực tế | `QueueStatus`, `QueueSummary` |

Ví dụ một lần `UpdateConfig` tạo group 610:

```
Action: UpdateConfig
SrcFilename: queues.conf
DstFilename: queues.conf
Reload: no
Action-000000: NewCat
Cat-000000: 610
Action-000001: Append
Cat-000001: 610
Var-000001: strategy
Value-000001: linear
Action-000002: Append
Cat-000002: 610
Var-000002: member
Value-000002: PJSIP/101,0,Nhan vien 101,PJSIP/101
```

Sau đó gửi `Action: QueueReload` / `Queue: 610` / `Members: yes` / `Parameters: yes`.

### Quyết định thứ tự đổ chuông

| `strategy` | Cách đổ | Thứ tự do đâu |
| --- | --- | --- |
| `linear` | Lần lượt, hết `timeout` sang người sau | **Thứ tự dòng `member`** |
| `ringall` | Tất cả cùng lúc | Không cần |
| `rrordered` | Xoay vòng, cuộc sau bắt đầu từ người kế tiếp | Thứ tự dòng `member` |
| `leastrecent` / `fewestcalls` | Người lâu nhất chưa nghe, hoặc nghe ít nhất | Asterisk tự tính |
| + `penalty` (số thứ 2 của `member =>`) | Nhóm penalty cao hơn chỉ được đổ khi nhóm thấp hơn **không ai rảnh** (bận hoặc chưa đăng nhập) | Giá trị penalty |

## 3. Việc phải sửa ở pbx-node (khi làm)

| File | Thay đổi |
| --- | --- |
| `asterisk/conf/extconfig.conf` | Bỏ `queues`, `queue_members` (không còn Realtime) |
| `asterisk/conf/queues.conf` | Thành file mẫu: `[general]` + group 600 với thứ tự mẫu |
| `asterisk/entrypoint.sh` | `queues.conf` để trong volume: **chỉ chép bản mẫu khi volume trống**. Hiện entrypoint chép đè mọi file từ `/opt/pbx-conf` mỗi lần khởi động, nên sẽ xóa thay đổi của Gateway |
| `docker-compose.yml` | Volume mới cho `queues.conf` (ví dụ `astconf-dyn`), **phải sao lưu** cùng `astdb` |
| `asterisk/conf/manager.conf.tmpl` | Thêm quyền ghi `config` cho user Gateway |
| `scripts/check-gateway-access.sh` | Thử `UpdateConfig` tạo + xóa một group tạm |
| `scripts/` (mới) | Chuyển group cũ từ bảng `queues`/`queue_members` sang `queues.conf` (chạy một lần) |
| `CLAUDE.md`, `README.md`, `docs/luu-y-trien-khai.md` | Ghi quyết định, cách sao lưu, cảnh báo bảo mật |

Hệ quả: PostgreSQL chỉ còn bảng `cdr`. Gateway đã nhận CDR qua sự kiện `Cdr`, nên về sau có thể cân nhắc bỏ PostgreSQL khỏi cụm.

## 4. Rủi ro, cần lưu ý

- **Bảo mật:** quyền AMI `config` sửa được **mọi** file trong `/etc/asterisk` (kể cả `manager.conf`, `extensions.conf`); Asterisk không giới hạn theo file. Ai có tài khoản AMI của Gateway là có toàn quyền tổng đài, tương đương quyền `system` hiện tại. Bắt buộc: AMI chỉ mở cho IP Gateway, mạng nội bộ/VPN, mật khẩu mạnh.
- **Dữ liệu dạng file:** toàn bộ cấu hình cụm nằm ở hai volume (`astdb`, `queues.conf`). Không có SQL, không có nhân bản; phải sao lưu định kỳ. Đây chính là lo ngại đã nêu với astdb.
- **Ghi đồng thời:** hai yêu cầu `UpdateConfig` cùng lúc có thể ghi đè nhau. Gateway nên tuần tự hóa các thao tác ghi theo từng cụm.
- **Chưa kiểm chứng trên Asterisk 20:** `UpdateConfig` với nhiều dòng `member` trùng tên (`Delete` có `Match`), thứ tự giữ đúng sau `QueueReload` và sau restart, `QueueReload` không rớt cuộc gọi đang chờ.

## 5. Cách khác đã cân nhắc

| Cách | Mô tả | Lý do không chọn làm chính |
| --- | --- | --- |
| 2. Queue cố định + thành viên động | `persistentmembers = yes`, Gateway `QueueAdd`/`QueueRemove` (lưu trong astdb); thứ tự `linear` = thứ tự thêm, hoặc dùng `penalty` | Không cần quyền `config` (an toàn hơn), nhưng **không tạo/sửa được group** qua AMI. Dùng được nếu danh sách group ít đổi |
| 3. Dialplan + astdb, bỏ `app_queue` | Gateway `DBPut` danh sách thành viên, dialplan tự `Dial` | Mất hàng chờ, nhạc chờ, pause, thống kê queue |

## 6. Bước tiếp theo

1. Chạy thử trên Docker cục bộ: tạo group, đổi thứ tự qua `UpdateConfig`, `QueueReload`, kiểm tra thứ tự đổ chuông `linear`, restart giữ dữ liệu, cuộc gọi đang chờ không rớt.
2. So với PA1 (PostgreSQL Realtime, Gateway ghi SQL) và chốt ở cuộc chat thiết kế.
3. Nếu chốt: làm theo mục 3, cập nhật `CLAUDE.md`.
