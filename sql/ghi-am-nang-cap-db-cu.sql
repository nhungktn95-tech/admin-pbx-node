-- ============================================================
-- Chỉ dùng khi DB ĐÃ khởi tạo từ trước (volume pgdata đã có dữ liệu):
-- thêm cột recordingfile vào cdr để lưu tên file ghi âm. DB mới tạo thì không cần.
--   docker compose exec -T db psql -U asterisk -d asterisk < sql/ghi-am-nang-cap-db-cu.sql
-- Sau đó: docker compose restart asterisk (cdr_adaptive_odbc đọc lại danh sách cột)
-- ============================================================
ALTER TABLE cdr ADD COLUMN IF NOT EXISTS recordingfile VARCHAR(255);
