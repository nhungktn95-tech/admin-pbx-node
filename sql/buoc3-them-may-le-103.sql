-- BƯỚC 3: thêm máy lẻ 103 khi Asterisk ĐANG CHẠY, không reload
-- Chạy: docker compose exec -T db psql -U asterisk -d asterisk < sql/buoc3-them-may-le-103.sql

BEGIN;
INSERT INTO ps_aors (id, max_contacts, remove_existing, qualify_frequency)
  VALUES ('103', 1, 'yes', 60);
-- Mật khẩu lab103pass lưu dạng md5('103:asterisk:lab103pass'), không lưu mật khẩu gốc
INSERT INTO ps_auths (id, auth_type, username, realm, md5_cred)
  VALUES ('103', 'md5', '103', 'asterisk', 'db66485b807be733f6b5b2847d44fd98');
INSERT INTO ps_endpoints (id, transport, aors, auth, context, disallow, allow,
                          direct_media, dtmf_mode, callerid,
                          force_rport, rewrite_contact, rtp_symmetric, allow_transfer)
  VALUES ('103', 'transport-udp', '103', '103', 'from-internal', 'all', 'ulaw,alaw',
          'no', 'rfc4733', '"Nhan vien 103" <103>', 'yes', 'yes', 'yes', 'yes');

-- Thêm 103 vào group 600
INSERT INTO queue_members (queue_name, interface, membername, state_interface)
  VALUES ('600', 'PJSIP/103', 'Nhan vien 103', 'PJSIP/103');
COMMIT;
