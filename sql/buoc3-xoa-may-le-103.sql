-- Xóa máy lẻ 103 (để làm lại bước 3)
BEGIN;
DELETE FROM queue_members WHERE interface = 'PJSIP/103';
DELETE FROM ps_endpoints WHERE id = '103';
DELETE FROM ps_auths     WHERE id = '103';
DELETE FROM ps_aors      WHERE id = '103';
COMMIT;
