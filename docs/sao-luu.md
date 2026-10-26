# Sao lưu và khôi phục cụm pbx-node

Kịch bản: [scripts/backup.sh](../scripts/backup.sh), [scripts/restore.sh](../scripts/restore.sh). Chạy **trên máy chủ**, trong thư mục project.

## 1. Sao lưu những gì

| Dữ liệu | Nơi lưu trong cụm | Mất thì sao | Trong bản sao lưu |
| --- | --- | --- | --- |
| Máy lẻ (endpoint/auth/aor) | astdb — volume `astdb` | Mọi máy lẻ biến mất, softphone không đăng ký được | `astdb.sqlite3` (`sqlite3 .backup`, nhất quán khi đang chạy, kiểm tra `integrity_check`) |
| Group (queue) | `/etc/asterisk/gateway/queues-groups.conf` — volume `astconf` | Mọi group biến mất (khởi động lại chỉ còn group mẫu 600) | `astconf.tar.gz` |
| Lịch sử cuộc gọi | bảng `cdr` — volume `pgdata` | Mất lịch sử | `db.dump` (`pg_dump -Fc`) |
| Chứng chỉ TLS/WSS | volume `astkeys` | Tạo lại chứng chỉ tự ký mới → mọi trình duyệt/softphone phải tin lại | `astkeys.tar.gz` |
| Menu IVR / lời chào IVR | astdb (khóa `ivr/...`) / volume `astivr` | Mất menu bấm phím / lời chào | trong `astdb.sqlite3` / `astivr.tar.gz` |
| Cấu hình môi trường | `.env` (mật khẩu AMI/ARI/DB) | Gateway không vào được nếu đặt mật khẩu khác | `env` (quyền 600) |
| Ghi âm | `/var/spool/asterisk/recording` — volume `recordings` hoặc `RECORDINGS_PATH` | Mất file ghi âm | **Riêng**, tùy chọn: `BACKUP_RECORDINGS=yes` → rsync tăng dần vào `<đích>/recordings/` |

Mã nguồn cấu hình (`asterisk/conf`, compose...) nằm trong git — không cần sao lưu.

## 2. Chạy tay

```bash
cd ~/project/admin-pbx-node
./scripts/backup.sh /backup/pbx          # hoặc không truyền: dùng BACKUP_DIR trong .env, mặc định ./backups
```
Kết quả: `/backup/pbx/pbx-node-YYYYmmdd-HHMMSS/` gồm `astdb.sqlite3`, `astconf.tar.gz`, `astkeys.tar.gz`, `astivr.tar.gz`, `db.dump`, `env`,
`MANIFEST` (số máy lẻ / group / dòng cdr, commit git), `SHA256SUMS`. Bản dở dang có tên `.pbx-node-*.partial` và bị xóa khi lỗi —
thư mục `pbx-node-*` luôn là bản hoàn chỉnh. Mã thoát khác 0 = lỗi.

Sao lưu không ngắt cuộc gọi. Cần image có `sqlite3` (Dockerfile đã thêm — `docker compose up -d --build` một lần);
image cũ thì script cảnh báo và chép thẳng file astdb.

## 3. Chạy tự động hằng ngày (cron)

Nên chạy bằng **root** (đọc được volume ghi âm trong `/var/lib/docker`) và ghi ra **ổ khác** ổ chạy Docker:

```bash
sudo crontab -e
# 02:30 mỗi ngày
30 2 * * * cd /home/ad/project/admin-pbx-node && ./scripts/backup.sh /backup/pbx >> /var/log/pbx-backup.log 2>&1
```

Biến trong `.env`:

| Biến | Mặc định | Ý nghĩa |
| --- | --- | --- |
| `BACKUP_DIR` | `./backups` | Thư mục đích (bị ghi đè bởi tham số dòng lệnh) |
| `BACKUP_KEEP_DAYS` | `14` | Xóa bản `pbx-node-*` cũ hơn số ngày này |
| `BACKUP_RECORDINGS` | `no` | `yes`: rsync tăng dần ghi âm vào `<đích>/recordings/` (cần `rsync`) |

**Sao lưu nằm cùng máy chủ thì vẫn mất khi máy chủ hỏng.** Thêm bước đẩy ra ngoài (máy khác / NAS / S3), ví dụ sau dòng cron trên:
```bash
45 2 * * * rsync -a --delete /backup/pbx/ backup@nas:/srv/pbx-backup/      # hoặc: rclone sync /backup/pbx s3:bucket/pbx
```
Bản sao lưu chứa mật khẩu (`env`) và ghi âm của người dân → nơi lưu phải giới hạn quyền truy cập, nên mã hóa.

## 4. Khôi phục

```bash
cd ~/project/admin-pbx-node
docker compose up -d                                   # container phải tồn tại (máy mới: git clone, .env, up -d --build trước)
./scripts/restore.sh /backup/pbx/pbx-node-20261022-023000
# chỉ một phần:  --parts astdb   |  --parts astconf   |  --parts db   |  --parts astdb,astconf
```

Script lần lượt:
1. Kiểm tra `SHA256SUMS`, hiện `MANIFEST`, hỏi xác nhận (gõ `KHOI PHUC`; tự động: `--yes`).
2. **Sao lưu trạng thái hiện tại** vào `<thư mục cha>/pre-restore/` — khôi phục nhầm thì khôi phục lại từ đó.
3. Dừng Asterisk (**ngắt cuộc gọi đang diễn ra**), ghi đè các phần được chọn, khởi động lại.
   File sao lưu hỏng → phần đó giữ nguyên dữ liệu cũ; **lỗi ở bước nào Asterisk cũng được khởi động lại**.
4. In số máy lẻ / group / dòng cdr sau khôi phục cạnh số trong `MANIFEST` để so.

Không tự khôi phục:
- `.env`: so tay với file `env` trong bản sao lưu (máy chủ mới thì chép `env` thành `.env`, sửa `HOST_IP` nếu đổi IP).
- Ghi âm: `rsync -a /backup/pbx/recordings/ <thư mục ghi âm>/` (lấy đường dẫn bằng
  `docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/spool/asterisk/recording"}}{{.Source}}{{end}}{{end}}' pbx-asterisk`).

Sau khôi phục: `pjsip show endpoints`, `queue show`, softphone đăng ký lại được, Admin UI thấy đủ máy lẻ/group.
Gateway (lưu dữ liệu riêng) không bị ảnh hưởng; nếu Gateway có chức năng đồng bộ cụm thì chạy lại đồng bộ.

## 5. Thử khôi phục định kỳ

Sao lưu chưa từng khôi phục thử thì chưa chắc dùng được. Mỗi quý: dựng cụm thử (Docker local hoặc máy phụ),
`restore.sh` bản mới nhất, kiểm tra như mục 4.

Đã thử trên Docker local (22/10/2026): sao lưu → xóa máy lẻ, thêm group lạ, thêm dòng cdr giả → khôi phục: số máy lẻ / group /
cdr khớp `MANIFEST`, dữ liệu lạ biến mất; file `astconf.tar.gz` hỏng → group cũ giữ nguyên, Asterisk tự khởi động lại.
