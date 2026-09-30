-- ============================================================
-- Chuyển mật khẩu máy lẻ từ dạng gốc (auth_type=userpass) sang md5_cred, xóa mật khẩu gốc.
-- Dùng cho DB ĐÃ khởi tạo từ trước. DB mới tạo từ db/init thì không cần.
-- Chạy lại nhiều lần được.
--   docker compose exec -T db psql -U asterisk -d asterisk < sql/bao-mat-mat-khau-md5.sql
-- md5_cred = md5(username:realm:mật_khẩu), realm = 'asterisk' (khớp default_realm trong pjsip.conf)
-- ============================================================
BEGIN;

ALTER TABLE ps_auths ADD COLUMN IF NOT EXISTS md5_cred VARCHAR(40);
ALTER TABLE ps_auths ADD COLUMN IF NOT EXISTS realm    VARCHAR(40);

UPDATE ps_auths
   SET md5_cred  = md5(username || ':asterisk:' || password),
       realm     = 'asterisk',
       auth_type = 'md5',
       password  = NULL
 WHERE password IS NOT NULL AND password <> '';

-- Từ nay DB từ chối mọi dòng có mật khẩu gốc
ALTER TABLE ps_auths DROP CONSTRAINT IF EXISTS ps_auths_khong_luu_mat_khau_goc;
ALTER TABLE ps_auths ADD CONSTRAINT ps_auths_khong_luu_mat_khau_goc
    CHECK (password IS NULL AND auth_type = 'md5' AND md5_cred ~ '^[0-9a-f]{32}$');

COMMIT;

SELECT id, auth_type, username, realm, md5_cred, password FROM ps_auths ORDER BY id;
