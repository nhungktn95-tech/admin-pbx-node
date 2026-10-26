"""
cdr-shipper: giao lịch sử cuộc gọi (bảng cdr của cụm) sang PBX Gateway, bảo đảm KHÔNG MẤT (docs/cdr-shipper.md).

Vì sao: sự kiện AMI "Cdr" là luồng gửi-rồi-quên — Gateway mất kết nối AMI là mất lịch sử. Bảng cdr trong cụm đã có đủ;
tiến trình này đọc bảng đó và ĐẨY sang API của Gateway, chỉ tiến lên khi Gateway xác nhận (acked_id), lỗi thì gửi lại.
Cụm không mở thêm cổng nào; Gateway không cần tài khoản DB của cụm. AMI "Cdr" vẫn chạy song song (thời gian thực),
Gateway chống trùng theo (cluster_id, uniqueid, sequence).

Vòng lặp:
  1. Mốc an toàn = max(cdr.id) đã thấy từ ít nhất SAFETY_LAG giây trước (dòng có id nhỏ có thể commit muộn hơn dòng id
     lớn vài mili giây; gửi vượt qua nó sẽ bỏ sót vĩnh viễn).
  2. Lấy tối đa BATCH dòng có  last_acked < id <= mốc an toàn, gửi POST; Gateway trả {"acked_id": N}.
  3. Lưu N vào STATE_FILE (ghi nguyên tử). Lỗi mạng/HTTP -> chờ tăng dần (tối đa 60 giây) rồi gửi lại đúng lô đó.
Chỉ dùng thư viện chuẩn Python + psycopg (driver PostgreSQL).
"""
import json
import os
import signal
import sys
import time
import urllib.error
import urllib.request
import ssl
from collections import deque
from datetime import datetime, date
from decimal import Decimal
from zoneinfo import ZoneInfo

import psycopg
from psycopg.rows import dict_row


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        sys.exit(f"[cdr-shipper] LỖI: thiếu biến môi trường {name}")
    return v


GATEWAY_CDR_URL = env("GATEWAY_CDR_URL", required=True)   # vd https://gateway.local/api/clusters/lab-02/cdr
CLUSTER_ID = env("CLUSTER_ID", required=True)
CDR_API_KEY = env("CDR_API_KEY", required=True)
DB_DSN = "host={h} port={p} dbname={d} user={u} password={pw} connect_timeout=5".format(
    h=env("DB_HOST", "db"), p=env("DB_PORT", "5432"), d=env("DB_NAME", "asterisk"),
    u=env("CDR_SHIPPER_DB_USER", "cdr_shipper"), pw=env("CDR_SHIPPER_DB_PASSWORD", required=True))
STATE_FILE = env("STATE_FILE", "/state/last_acked_id")
INTERVAL = float(env("CDR_SHIP_INTERVAL", "5"))           # giây giữa hai lần quét khi không còn dòng chờ
BATCH = int(env("CDR_SHIP_BATCH", "500"))
SAFETY_LAG = float(env("CDR_SHIP_SAFETY_LAG", "5"))        # giây
START = env("CDR_SHIP_START", "all")                       # lần chạy đầu: all = gửi toàn bộ lịch sử, now = chỉ từ bây giờ
TZ = ZoneInfo(env("TZ", "Asia/Ho_Chi_Minh"))               # cdr.calldate lưu giờ địa phương không kèm múi giờ
HTTP_TIMEOUT = float(env("CDR_SHIP_HTTP_TIMEOUT", "15"))
WARN_PENDING_MIN = float(env("CDR_SHIP_WARN_MINUTES", "10"))  # cảnh báo khi có dòng chờ giao quá số phút này

ssl_ctx = ssl.create_default_context(cafile=env("GATEWAY_CA_FILE") or None)
if env("GATEWAY_TLS_INSECURE", "no") == "yes":             # chỉ dùng ở lab (Gateway chứng chỉ tự ký)
    ssl_ctx.check_hostname = False
    ssl_ctx.verify_mode = ssl.CERT_NONE

running = True


def log(msg):
    print(f"[cdr-shipper] {datetime.now(TZ).strftime('%F %T')} {msg}", flush=True)


def stop(*_):
    global running
    running = False


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)


def read_state():
    try:
        with open(STATE_FILE) as f:
            return int(f.read().strip())
    except FileNotFoundError:
        return None


def write_state(n):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        f.write(str(n))
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)


def to_json_value(v):
    if isinstance(v, datetime):
        return (v if v.tzinfo else v.replace(tzinfo=TZ)).isoformat()
    if isinstance(v, date):
        return v.isoformat()
    if isinstance(v, Decimal):
        return int(v) if v == v.to_integral_value() else float(v)
    return v


def post_batch(rows):
    """Gửi một lô. Trả acked_id (int) hoặc ném lỗi."""
    body = json.dumps({
        "cluster_id": CLUSTER_ID,
        "first_id": rows[0]["id"],
        "last_id": rows[-1]["id"],
        "rows": [{k: to_json_value(v) for k, v in r.items()} for r in rows],
    }).encode()
    req = urllib.request.Request(GATEWAY_CDR_URL, data=body, method="POST", headers={
        "Content-Type": "application/json",
        "Authorization": f"Bearer {CDR_API_KEY}",
        "X-Cluster-Id": CLUSTER_ID,
    })
    with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=ssl_ctx) as resp:
        data = json.loads(resp.read() or b"{}")
    acked = data.get("acked_id")
    if not isinstance(acked, int):
        raise ValueError(f"Gateway trả thiếu/sai acked_id: {data}")
    return acked


def main():
    log(f"Khởi động: cụm={CLUSTER_ID} -> {GATEWAY_CDR_URL} (lô {BATCH}, quét {INTERVAL}s, trễ an toàn {SAFETY_LAG}s)")
    seen = deque()            # (thời điểm, max_id) để tính mốc an toàn
    backoff = 1.0
    last = read_state()
    conn = None
    pending_since = None
    while running:
        try:
            if conn is None or conn.closed:
                conn = psycopg.connect(DB_DSN, autocommit=True, row_factory=dict_row)
                log("Đã kết nối database")
            with conn.cursor() as cur:
                cur.execute("SELECT coalesce(max(id), 0) AS m FROM cdr")
                max_id = cur.fetchone()["m"]
            if last is None:                    # lần chạy đầu tiên (chưa có trạng thái)
                last = max_id if START == "now" else 0
                write_state(last)
                log(f"Lần đầu chạy (CDR_SHIP_START={START}): bắt đầu sau id {last}")
            if max_id < last:                   # bảng cdr bị khôi phục/xóa: id quay về nhỏ hơn mốc đã giao
                log(f"CẢNH BÁO: max(cdr.id)={max_id} < đã giao {last} (DB được khôi phục?). Gửi lại từ đầu; Gateway tự chống trùng")
                last = 0
                write_state(last)
            now = time.monotonic()
            seen.append((now, max_id))
            safe = None
            while seen and now - seen[0][0] >= SAFETY_LAG:
                safe = seen.popleft()[1]
            if safe is not None:
                seen.appendleft((now - SAFETY_LAG, safe))   # giữ lại mốc vừa dùng cho lần sau
            if safe is None or safe <= last:
                if max_id <= last:
                    pending_since = None
                time.sleep(INTERVAL if max_id <= last else 1)
                continue

            with conn.cursor() as cur:
                cur.execute("SELECT * FROM cdr WHERE id > %s AND id <= %s ORDER BY id LIMIT %s", (last, safe, BATCH))
                rows = cur.fetchall()
            if not rows:
                time.sleep(INTERVAL)
                continue
            pending_since = pending_since or time.time()

            acked = post_batch(rows)
            if acked < last or acked > rows[-1]["id"]:
                raise ValueError(f"acked_id={acked} nằm ngoài lô ({last}..{rows[-1]['id']})")
            if acked > last:
                write_state(acked)
                log(f"Đã giao {sum(1 for r in rows if r['id'] <= acked)} dòng (id {rows[0]['id']}..{acked})")
                last = acked
            backoff = 1.0
            if last >= max_id:
                pending_since = None
            # Còn dòng chờ (lô đầy, hoặc Gateway mới xác nhận một phần lô) -> gửi tiếp ngay, không ngủ
            if len(rows) < BATCH and acked >= rows[-1]["id"]:
                time.sleep(INTERVAL)
        except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError, psycopg.Error) as e:
            detail = e
            if isinstance(e, urllib.error.HTTPError):
                detail = f"HTTP {e.code} {e.read()[:200]!r}"
            log(f"Lỗi: {detail} — thử lại sau {backoff:.0f}s")
            if isinstance(e, psycopg.Error) and conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
                conn = None
            if pending_since and time.time() - pending_since > WARN_PENDING_MIN * 60:
                log(f"CẢNH BÁO: có lịch sử chưa giao được cho Gateway quá {WARN_PENDING_MIN:.0f} phút (đang chờ sau id {last})")
            for _ in range(int(backoff)):
                if not running:
                    break
                time.sleep(1)
            backoff = min(backoff * 2, 60)
    log("Dừng")


if __name__ == "__main__":
    main()
