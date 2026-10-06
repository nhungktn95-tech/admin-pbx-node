# Phân tích: lưu máy lẻ PJSIP ở đâu và PBX Gateway ghi vào bằng cách nào

> Trạng thái: **chờ chốt** ở cuộc chat thiết kế. Ngày viết: 06/10/2026.
> Bối cảnh: Bước G2 (chưa commit) đã chuyển máy lẻ sang astdb để Gateway chỉ dùng ARI + AMI.
> Lo ngại: astdb khó quản lý và kém an toàn khi số máy lẻ tăng; mong muốn giữ PostgreSQL Realtime.

## 1. Bài toán

Cần quyết định hai việc gắn liền với nhau:

1. **Máy lẻ** (3 đối tượng `endpoint`, `auth`, `aor`) lưu ở đâu: PostgreSQL, MySQL, hay astdb (SQLite nội bộ của Asterisk).
2. **PBX Gateway** tạo, sửa, xóa máy lẻ bằng đường nào: ghi SQL thẳng vào DB của cụm, hay gọi ARI Push Configuration (`PUT/DELETE /ari/asterisk/config/dynamic/res_pjsip/...`).

Yêu cầu chung: máy lẻ có hiệu lực ngay, không reload; quản lý được hàng nghìn máy lẻ trên nhiều cụm; an toàn; vận hành đơn giản.
Liên quan: **group (queue)** cũng cần được Gateway quản lý.

## 2. Sự thật kỹ thuật làm nền

| # | Sự thật | Nguồn |
| --- | --- | --- |
| F1 | Khi tạo hoặc sửa máy lẻ qua ARI, Asterisk ghi **mọi thuộc tính** của đối tượng (endpoint có khoảng 150), không chỉ các trường được gửi lên | Đã thử ở G2 |
| F2 | Driver Realtime ghép tên cột vào SQL **không có nháy kép**: `res_config_odbc.c` (`", %s", field->name`), `res_config_pgsql.c` (`"%s = '%s'", field->name`) | Mã nguồn nhánh `master` trên GitHub, đọc ngày 06/10/2026 |
| F3 | Endpoint có thuộc tính `100rel`. PostgreSQL báo **lỗi cú pháp** với tên bắt đầu bằng chữ số mà không có nháy. Không có cách sửa phía DB (view, rule) vì câu lệnh hỏng ngay lúc phân tích cú pháp | Đã thử ở G2 |
| F4 | → **ARI + PostgreSQL Realtime không dùng được ở mọi phiên bản Asterisk**, kể cả bản mới nhất. Nâng cấp không giải quyết được | F1 + F2 + F3 |
| F5 | `res_config_odbc` khi UPDATE có giới hạn 64 thuộc tính: từ thuộc tính thứ 65 trở đi không kiểm tra cột có tồn tại hay không | Mã nguồn `update_odbc` |
| F6 | MySQL/MariaDB **cho phép** tên cột không nháy bắt đầu bằng chữ số (`100rel` hợp lệ) | Tài liệu MySQL. **Chưa thử với Asterisk** |
| F7 | Chiều **Asterisk đọc** PostgreSQL Realtime hoạt động tốt (đã chạy ở bước 1–3 và G1) | Đã chạy thực tế |
| F8 | ARI Push Configuration chỉ dùng cho module chạy trên sorcery (`res_pjsip`). **Queue (`app_queue`) không đi qua ARI được**; AMI `QueueAdd` chỉ thêm thành viên tạm, mất khi restart (`persistentmembers = no`) và không tạo được queue | Tài liệu Asterisk, cấu hình hiện tại |
| F9 | astdb là SQLite: hàng chục nghìn máy lẻ vẫn nhanh. Điểm yếu nằm ở quản lý, không phải hiệu năng | Đặc điểm SQLite |

## 3. Các phương án

### PA1. PostgreSQL Realtime, Gateway ghi SQL thẳng (thiết kế G1)

Gateway dùng user `GW_DB_USER` (quyền tối thiểu) để INSERT/UPDATE/DELETE `ps_*`, `queues`, `queue_members`. Asterisk đọc Realtime.

- **Ưu:** chạy với mọi phiên bản, đã kiểm chứng (F7). Quản lý được cả queue. SQL đầy đủ cho tìm kiếm, thống kê. Sao lưu, nhân bản, phân quyền, ràng buộc dữ liệu đều theo chuẩn PostgreSQL. Ít thay đổi nhất (hoàn lại G2).
- **Nhược:** Gateway phụ thuộc DB của cụm: phải mở 5432 cho Gateway, Gateway phải biết schema `ps_*` (gắn với phiên bản Asterisk).

### PA2. astdb + ARI (G2 hiện tại)

Máy lẻ lưu trong SQLite nội bộ của Asterisk, Gateway ghi qua ARI.

- **Ưu:** Gateway chỉ cần AMI + ARI, không biết DB. Đã làm xong và thử trên Docker cục bộ.
- **Nhược:** không có SQL để quản lý; mỗi cụm một file riêng; sao lưu phải tự lo (volume `astdb`); không có nhân bản; không có phân quyền hay ràng buộc. Queue vẫn không quản lý được (F8). `pjsip show endpoints` hiện mỗi máy hai lần (chưa rõ AMI/ARI có bị trùng không).
- **Bổ sung cho phần queue:** group lưu trong `queues.conf`, Gateway sửa qua AMI `UpdateConfig` + `QueueReload` (chưa thử). Xem [phuong-an-queue-qua-ami.md](phuong-an-queue-qua-ami.md).

### PA3. MySQL/MariaDB Realtime + ARI

Đổi lớp DB sang MariaDB, dùng schema đầy đủ của Asterisk (Alembic), driver `odbc-mariadb`.

- **Ưu:** có thể vừa dùng ARI vừa có SQL (F6).
- **Nhược:** **chưa kiểm chứng**. Còn rủi ro F5 khi sửa máy lẻ. Phải dùng schema đầy đủ (khoảng 150 cột) vì F1. Đổi toàn bộ lớp DB: image, schema, seed, user, script, tài liệu, chuyển dữ liệu `cdr`. Queue vẫn không đi qua ARI (F8).

### PA4. astdb nhận trước, job chuyển sang PostgreSQL, sau đó quản lý bằng PostgreSQL

- **Nhược, và lý do không khuyến nghị:**
  - Máy lẻ đã nằm trong PostgreSQL thì sửa qua ARI lại gặp F4. Vì vậy sửa, xóa phải ghi thẳng DB, tức Gateway (hoặc một service trên cụm, chính là pbx-agent đã bỏ) vẫn phụ thuộc DB. Mức phụ thuộc giống PA1, mà phức tạp hơn.
  - Hai nguồn dữ liệu cho cùng một máy lẻ: bản nào thắng, danh sách bị trùng, sửa trong lúc chờ job, job lỗi giữa chừng.

### PA5. astdb là nguồn chính + chép một chiều sang PostgreSQL để xem

Như PA2, thêm job định kỳ chép astdb sang một bảng **chỉ để đọc** (Asterisk không đọc bảng này).

- **Ưu:** Gateway chỉ dùng ARI; có SQL để xem và thống kê; dữ liệu một chiều nên không xung đột.
- **Nhược:** vẫn không sửa được bằng SQL; thêm một thành phần phải vận hành; dữ liệu xem bị trễ. Sao lưu và an toàn của nguồn chính vẫn là astdb. Queue vẫn không quản lý được.

### PA6. Tự vá Asterisk (đặt tên cột trong nháy kép) + PostgreSQL + ARI

- **Ưu:** giữ cả ARI lẫn PostgreSQL.
- **Nhược:** trái quyết định "Asterisk từ gói Ubuntu, không tự build". Mỗi lần nâng cấp phải vá và build lại. Có thể gửi bản vá lên Asterisk, nhưng không biết khi nào được nhận. Queue vẫn không đi qua ARI.

## 4. So sánh theo từng khía cạnh

Ký hiệu: ✅ tốt · ⚠️ được, kèm điều kiện · ❌ không đáp ứng

| Khía cạnh | PA1 PG + Gateway ghi SQL | PA2 astdb + ARI | PA3 MySQL + ARI | PA4 astdb → job → PG | PA5 astdb + bản xem PG | PA6 Vá Asterisk |
| --- | --- | --- | --- | --- | --- | --- |
| Chạy được, đã kiểm chứng | ✅ Đã chạy | ✅ Thử cục bộ | ⚠️ Chưa thử | ⚠️ Phức tạp | ✅ | ⚠️ Chưa thử |
| Hiệu lực ngay | ✅ | ✅ | ✅ | ❌ Trễ theo job | ✅ | ✅ |
| Gateway không cần DB của cụm | ❌ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Quản lý queue (group) | ✅ | ❌ | ❌ | ⚠️ Qua DB | ❌ | ❌ |
| Tìm kiếm, thống kê bằng SQL | ✅ | ❌ | ✅ | ✅ | ⚠️ Chỉ xem, có trễ | ✅ |
| Sao lưu, khôi phục | ✅ pg_dump, PITR | ⚠️ Tự lo file | ✅ | ⚠️ Hai nơi | ⚠️ Nguồn chính là file | ✅ |
| Nhân bản, chịu lỗi | ✅ | ❌ | ✅ | ⚠️ | ❌ | ✅ |
| Phân quyền, ràng buộc dữ liệu | ✅ | ❌ | ✅ | ⚠️ | ❌ | ✅ |
| Nhiều cụm, nhìn tổng thể | ✅ | ❌ | ✅ | ⚠️ | ⚠️ | ✅ |
| Một nguồn dữ liệu duy nhất | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Bề mặt tấn công | ⚠️ Mở 5432 cho IP Gateway | ⚠️ ARI có quyền ghi máy lẻ | ⚠️ Như PA2 | ❌ Cả hai | ⚠️ Như PA2 | ⚠️ Như PA2 |
| Độ phức tạp vận hành | ✅ Thấp | ✅ Thấp | ⚠️ Trung bình | ❌ Cao | ⚠️ Trung bình | ❌ Cao (build riêng) |
| Thay đổi ở pbx-node | ✅ Hoàn lại G2 | ✅ Đã xong | ❌ Đổi cả lớp DB | ❌ | ⚠️ Thêm job | ❌ Build Asterisk |
| Thay đổi ở pbx-gateway | ⚠️ Ghi SQL thay ARI | ✅ | ✅ | ❌ | ✅ | ✅ |
| Hợp quyết định đã chốt | ✅ (G1) | ⚠️ (G2, chưa chốt) | ❌ Đổi DB | ❌ Giống pbx-agent | ⚠️ | ❌ Tự build |

## 5. Khuyến nghị

**Chọn PA1: PostgreSQL Realtime, Gateway ghi SQL thẳng.** Lý do:

1. Chỉ PA1 đáp ứng đồng thời quản lý bằng SQL, an toàn dữ liệu (sao lưu, nhân bản, ràng buộc) **và** quản lý được queue.
2. Đã chạy thực tế, không phụ thuộc lỗi của Asterisk (F4), không cần tự build.
3. Nhược điểm duy nhất là Gateway phụ thuộc DB của cụm. Nhược điểm này kiểm soát được bằng các biện pháp ở mục 6.

**Giảm rủi ro cho tương lai:** trong `pbx-gateway`, đặt phần ghi máy lẻ sau một interface (ví dụ `ExtensionStore`), bản cài đặt hiện tại là SQL. Nếu sau này Asterisk sửa lỗi đặt tên cột trong nháy, hoặc chuyển sang MySQL, chỉ cần thêm bản cài đặt ARI mà không sửa phần còn lại.

**Không khuyến nghị:** PA4 (hai nguồn dữ liệu, phụ thuộc DB giống PA1) và PA6 (tự build Asterisk).
**Cân nhắc lại khi:** bắt buộc Gateway không được chạm DB của cụm. Khi đó cần thử PA3 trước (khoảng nửa ngày). Nếu không đạt thì dùng PA2 hoặc PA5, và phải có phương án riêng cho queue.

## 6. Biện pháp an toàn cho PA1

| Biện pháp | Trạng thái |
| --- | --- |
| User riêng cho Gateway, chỉ ghi `ps_*`/`queues`/`queue_members`, chỉ đọc `cdr` (`03-gateway-user.sh`) | Đã có |
| 5432 chỉ mở cho IP Gateway (`ADMIN_BIND` + firewall), qua mạng nội bộ/VPN | Đã có |
| Không lưu mật khẩu máy lẻ dạng gốc (`md5_cred`, CHECK `password IS NULL`) | Đã có |
| Mã hóa kết nối Gateway sang PostgreSQL (`ssl = on`, Gateway dùng `sslmode=require`) | **Cần thêm** |
| Nhật ký thay đổi máy lẻ (trigger ghi bảng lịch sử: ai, lúc nào, đổi gì) | Nên thêm |
| Sao lưu định kỳ `pgdata` (pg_dump hằng ngày + giữ N bản) | Cần thêm |

## 7. Việc phải làm nếu chốt PA1

**pbx-node**
- Hoàn lại `asterisk/conf/sorcery.conf`, `asterisk/conf/extconfig.conf` về realtime `ps_*`.
- Bỏ volume `astdb`, đoạn đổi `astdbdir` trong `asterisk/entrypoint.sh`, script `scripts/chuyen-may-le-sang-astdb.sh`.
- `scripts/check-gateway-access.sh`: khôi phục kiểm tra DB.
- Giữ lại: sửa múi giờ, ghi âm, `cdr_manager.conf` (sự kiện `Cdr` qua AMI).
- Thêm: SSL cho PostgreSQL; (tùy chọn) trigger nhật ký.
- Cập nhật `CLAUDE.md` (mục 2, 3, 4b), `README.md`, `docs/luu-y-trien-khai.md`.

**pbx-gateway**
- Phần tạo/sửa/xóa máy lẻ: chuyển từ ARI Push Configuration về ghi SQL (sau interface `ExtensionStore`).
- Thêm quản lý queue qua SQL.
- Kết nối DB với `sslmode=require`.

## 8. Câu hỏi cần chốt

1. Có chấp nhận Gateway kết nối DB của cụm (PA1) không? Nếu **không**: thử PA3 trước rồi mới quyết định.
2. Queue quản lý ra sao nếu không chọn PA1?
3. Có cần nhật ký thay đổi máy lẻ (truy vết) ngay từ đầu không?
