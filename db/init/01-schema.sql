-- ============================================================
-- Schema Realtime tối thiểu cho Asterisk 20 (PJSIP + Queue + CDR)
-- Tên cột trùng tên tham số cấu hình của Asterisk.
-- Giá trị yes/no lưu dạng chữ.
-- ============================================================

-- Máy lẻ: thông tin cuộc gọi
CREATE TABLE ps_endpoints (
    id               VARCHAR(40) PRIMARY KEY,   -- số máy lẻ, ví dụ '101'
    transport        VARCHAR(40),
    aors             VARCHAR(200),
    auth             VARCHAR(40),
    context          VARCHAR(40),               -- dialplan context: from-internal
    disallow         VARCHAR(200),
    allow            VARCHAR(200),
    direct_media     VARCHAR(3),
    dtmf_mode        VARCHAR(10),               -- rfc4733
    callerid         VARCHAR(80),
    force_rport      VARCHAR(3),
    rewrite_contact  VARCHAR(3),
    rtp_symmetric    VARCHAR(3),
    allow_transfer   VARCHAR(3),
    mailboxes        VARCHAR(40),
    webrtc           VARCHAR(3)                 -- yes: máy lẻ web (Softphone SDK), tự bật DTLS/ICE/AVPF
);

-- Máy lẻ: thông tin đăng nhập. KHÔNG lưu mật khẩu gốc.
--   auth_type = 'md5', md5_cred = md5(username || ':' || realm || ':' || mật_khẩu), realm = 'asterisk'
--   (SIP Digest bắt buộc server giữ giá trị HA1 này; không dùng bcrypt được)
CREATE TABLE ps_auths (
    id         VARCHAR(40) PRIMARY KEY,
    auth_type  VARCHAR(20),                     -- md5
    username   VARCHAR(40),
    password   VARCHAR(80),                     -- luôn NULL (xem ràng buộc bên dưới)
    md5_cred   VARCHAR(40),                     -- HA1, 32 ký tự hex
    realm      VARCHAR(40),                     -- phải khớp default_realm trong pjsip.conf
    CONSTRAINT ps_auths_khong_luu_mat_khau_goc
        CHECK (password IS NULL AND auth_type = 'md5' AND md5_cred ~ '^[0-9a-f]{32}$')
);

-- Máy lẻ: nơi thiết bị đăng nhập (AOR)
CREATE TABLE ps_aors (
    id                 VARCHAR(40) PRIMARY KEY,
    max_contacts       INTEGER,                 -- số thiết bị được đăng nhập cùng lúc
    remove_existing    VARCHAR(3),
    qualify_frequency  INTEGER                  -- giây, Asterisk kiểm tra thiết bị còn sống
);

-- Group (queue)
CREATE TABLE queues (
    name            VARCHAR(40) PRIMARY KEY,    -- số group, ví dụ '600'
    strategy        VARCHAR(20),                -- ringall, rrmemory, leastrecent...
    timeout         INTEGER,                    -- giây đổ chuông mỗi lượt
    retry           INTEGER,
    wrapuptime      INTEGER,
    ringinuse       VARCHAR(3),
    joinempty       VARCHAR(40),
    leavewhenempty  VARCHAR(40),
    musiconhold     VARCHAR(40)
);

-- Thành viên group
CREATE TABLE queue_members (
    uniqueid         SERIAL PRIMARY KEY,
    queue_name       VARCHAR(40) NOT NULL REFERENCES queues(name) ON DELETE CASCADE,
    interface        VARCHAR(80) NOT NULL,      -- PJSIP/101
    membername       VARCHAR(80),
    state_interface  VARCHAR(80),
    penalty          INTEGER DEFAULT 0,
    paused           INTEGER DEFAULT 0,
    reason_paused    VARCHAR(80),
    wrapuptime       INTEGER,
    ringinuse        VARCHAR(3),
    UNIQUE (queue_name, interface)
);

-- Lịch sử cuộc gọi (Asterisk tự ghi sau mỗi cuộc)
CREATE TABLE cdr (
    id           BIGSERIAL PRIMARY KEY,
    calldate     TIMESTAMP,
    clid         VARCHAR(80),
    src          VARCHAR(80),
    dst          VARCHAR(80),
    dcontext     VARCHAR(80),
    channel      VARCHAR(80),
    dstchannel   VARCHAR(80),
    lastapp      VARCHAR(80),
    lastdata     VARCHAR(200),
    duration     INTEGER,
    billsec      INTEGER,
    disposition  VARCHAR(45),
    amaflags     VARCHAR(20),
    accountcode  VARCHAR(40),
    uniqueid     VARCHAR(150),
    userfield    VARCHAR(255),
    linkedid     VARCHAR(150),
    peeraccount  VARCHAR(40),
    sequence     INTEGER,
    recordingfile VARCHAR(255)              -- tên file ghi âm (không đuôi .wav), tải qua ARI /recordings/stored
);
CREATE INDEX cdr_calldate_idx ON cdr (calldate);
CREATE INDEX cdr_linkedid_idx ON cdr (linkedid);
