"""
Gateway GIẢ để thử cdr-shipper (không dùng cho môi trường thật). Làm đúng hợp đồng trong docs/cdr-shipper.md:
  POST <đường dẫn bất kỳ>, Authorization: Bearer <API_KEY>, JSON {cluster_id, first_id, last_id, rows[]}
  -> lưu theo khóa (cluster_id, uniqueid, sequence) (trùng thì bỏ qua) -> 200 {"acked_id": last_id}
Điều khiển khi thử:
  FAIL_FILE tồn tại       -> trả 503 (giả Gateway lỗi)
  ACK_PARTIAL=yes         -> chỉ xác nhận một nửa lô (giả Gateway xử lý dở)
  GET /stats              -> {"rows": số dòng duy nhất, "dups": số dòng trùng bị bỏ, "batches": số lô}
Chạy: python fake_gateway.py   (PORT mặc định 8099, API_KEY mặc định test-key)
"""
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8099"))
API_KEY = os.environ.get("API_KEY", "test-key")
FAIL_FILE = os.environ.get("FAIL_FILE", "/tmp/gateway-fail")
store, stats = {}, {"rows": 0, "dups": 0, "batches": 0}


class H(BaseHTTPRequestHandler):
    def _send(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        self._send(200, stats if self.path == "/stats" else {"ok": True})

    def do_POST(self):
        if self.headers.get("Authorization") != f"Bearer {API_KEY}":
            return self._send(401, {"error": "sai API key"})
        if os.path.exists(FAIL_FILE):
            return self._send(503, {"error": "Gateway giả đang lỗi"})
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))
        rows = body["rows"]
        if os.environ.get("ACK_PARTIAL") == "yes" and len(rows) > 1:
            rows = rows[: len(rows) // 2]
        for r in rows:
            key = (body["cluster_id"], r["uniqueid"], r["sequence"])
            if key in store:
                stats["dups"] += 1
            else:
                store[key] = r
                stats["rows"] += 1
        stats["batches"] += 1
        acked = rows[-1]["id"] if rows else body["first_id"] - 1
        print(f"lô {body['first_id']}..{body['last_id']}: {len(rows)} dòng, acked={acked}, tổng={stats['rows']}", flush=True)
        self._send(200, {"acked_id": acked})

    def log_message(self, *a):
        pass


ThreadingHTTPServer(("0.0.0.0", PORT), H).serve_forever()
