-- Xem nhanh dữ liệu trong Realtime DB
SELECT e.id AS may_le, e.callerid, e.context, a.max_contacts
  FROM ps_endpoints e JOIN ps_aors a ON a.id = e.id ORDER BY e.id;

SELECT q.name AS group_so, q.strategy, m.interface
  FROM queues q LEFT JOIN queue_members m ON m.queue_name = q.name ORDER BY 1, 3;

-- 10 cuộc gọi gần nhất
SELECT calldate, src, dst, disposition, duration, billsec, linkedid
  FROM cdr ORDER BY id DESC LIMIT 10;
