-- ============================================================
-- Dữ liệu mẫu cho bước 1 và 2
--   101, 102: máy lẻ người thật (softphone)
--   201     : máy lẻ AI (lab: dùng softphone đóng vai AI)
--   600     : group đổ chuông 101 + 102
-- Mật khẩu chỉ dùng cho lab, KHÔNG dùng ở môi trường thật.
-- ============================================================

-- 1 máy lẻ = 1 dòng ở 3 bảng: ps_aors, ps_auths, ps_endpoints
INSERT INTO ps_aors (id, max_contacts, remove_existing, qualify_frequency) VALUES
  ('101', 1, 'yes', 60),
  ('102', 1, 'yes', 60),
  ('201', 1, 'yes', 60);

-- Mật khẩu lưu dạng md5_cred = md5('<user>:asterisk:<mật khẩu>'), không lưu mật khẩu gốc.
-- Mật khẩu lab để đăng nhập softphone xem README (labXXXpass).
INSERT INTO ps_auths (id, auth_type, username, realm, md5_cred) VALUES
  ('101', 'md5', '101', 'asterisk', '0a1555147d8b7af827be037fd849ff6f'),
  ('102', 'md5', '102', 'asterisk', 'd5a7e35407ee1545468a06540596cf23'),
  ('201', 'md5', '201', 'asterisk', '5ba9cf2a2e0b5cf2a953a8df404a8d58');

INSERT INTO ps_endpoints (id, transport, aors, auth, context, disallow, allow,
                          direct_media, dtmf_mode, callerid,
                          force_rport, rewrite_contact, rtp_symmetric, allow_transfer) VALUES
  ('101', 'transport-udp', '101', '101', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Nhan vien 101" <101>', 'yes', 'yes', 'yes', 'yes'),
  ('102', 'transport-udp', '102', '102', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Nhan vien 102" <102>', 'yes', 'yes', 'yes', 'yes'),
  ('201', 'transport-udp', '201', '201', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Tro ly AI" <201>',    'yes', 'yes', 'yes', 'yes');

-- Group 600: đổ chuông tất cả thành viên cùng lúc, mỗi lượt 20 giây
INSERT INTO queues (name, strategy, timeout, retry, wrapuptime, ringinuse, joinempty, leavewhenempty) VALUES
  ('600', 'ringall', 20, 2, 0, 'no', 'yes', 'no');

INSERT INTO queue_members (queue_name, interface, membername, state_interface) VALUES
  ('600', 'PJSIP/101', 'Nhan vien 101', 'PJSIP/101'),
  ('600', 'PJSIP/102', 'Nhan vien 102', 'PJSIP/102');

-- ============================================================
-- Máy lẻ WEB 150, 151: đăng nhập từ trình duyệt (Softphone SDK) qua WSS 8089
-- webrtc=yes: Asterisk tự bật mã hóa DTLS-SRTP, ICE, AVPF như trình duyệt yêu cầu
-- ============================================================
INSERT INTO ps_aors (id, max_contacts, remove_existing, qualify_frequency) VALUES
  ('150', 1, 'yes', 60),
  ('151', 1, 'yes', 60);

INSERT INTO ps_auths (id, auth_type, username, realm, md5_cred) VALUES
  ('150', 'md5', '150', 'asterisk', '097e485099cf5f4949d47122c4e6ea07'),
  ('151', 'md5', '151', 'asterisk', '18002a159b7a71e7e1ac5fbeb56a914d');

INSERT INTO ps_endpoints (id, transport, aors, auth, context, disallow, allow,
                          direct_media, dtmf_mode, callerid,
                          force_rport, rewrite_contact, rtp_symmetric, allow_transfer, webrtc) VALUES
  ('150', 'transport-wss', '150', '150', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Web 150" <150>', 'yes', 'yes', 'yes', 'yes', 'yes'),
  ('151', 'transport-wss', '151', '151', 'from-internal', 'all', 'ulaw,alaw', 'no', 'rfc4733', '"Web 151" <151>', 'yes', 'yes', 'yes', 'yes', 'yes');
