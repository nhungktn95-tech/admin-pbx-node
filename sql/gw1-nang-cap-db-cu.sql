-- ============================================================
-- Chỉ dùng khi DB ĐÃ khởi tạo từ trước (volume pgdata đã có dữ liệu):
-- thêm cột webrtc + máy lẻ web 150, 151. DB mới tạo thì không cần.
--   docker compose exec -T db psql -U asterisk -d asterisk < sql/bao-mat-mat-khau-md5.sql
--   docker compose exec -T db psql -U asterisk -d asterisk < sql/gw1-nang-cap-db-cu.sql
-- ============================================================
ALTER TABLE ps_endpoints ADD COLUMN IF NOT EXISTS webrtc VARCHAR(3);

INSERT INTO ps_aors (id, max_contacts, remove_existing, qualify_frequency) VALUES
  ('150', 1, 'yes', 60), ('151', 1, 'yes', 60)
ON CONFLICT (id) DO NOTHING;

-- Cần chạy sql/bao-mat-mat-khau-md5.sql TRƯỚC (tạo cột md5_cred, realm)
INSERT INTO ps_auths (id, auth_type, username, realm, md5_cred) VALUES
  ('150', 'md5', '150', 'asterisk', '097e485099cf5f4949d47122c4e6ea07'),
  ('151', 'md5', '151', 'asterisk', '18002a159b7a71e7e1ac5fbeb56a914d')
ON CONFLICT (id) DO NOTHING;

INSERT INTO ps_endpoints (id, transport, aors, auth, context, disallow, allow,
                          direct_media, dtmf_mode, callerid,
                          force_rport, rewrite_contact, rtp_symmetric, allow_transfer, webrtc) VALUES
  ('150', 'transport-wss', '150', '150', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Web 150" <150>', 'yes', 'yes', 'yes', 'yes', 'yes'),
  ('151', 'transport-wss', '151', '151', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Web 151" <151>', 'yes', 'yes', 'yes', 'yes', 'yes')
ON CONFLICT (id) DO NOTHING;
