# cdr-shipper — giao lịch sử cuộc gọi sang PBX Gateway không mất dữ liệu

## 1. Vì sao cần

Gateway nhận lịch sử qua sự kiện AMI `Cdr` (`cdr_manager.conf`). AMI là luồng **gửi rồi quên**: Gateway khởi động lại, mạng chập
chờn, đọc chậm quá `writetimeout` → sự kiện **mất hẳn**; AMI/ARI không có lệnh lấy lại CDR cũ. Không đưa tài khoản DB của cụm
cho Gateway (nguyên tắc G2).

Giải pháp: cụm tự **đẩy** bảng `cdr` (đã có đủ dữ liệu) sang **API của Gateway**, chỉ tiến lên khi Gateway xác nhận.

```
Asterisk ──ghi khi cúp máy──▶ bảng cdr (PostgreSQL trong cụm = "hộp thư đi")
   │                              │ đọc (user cdr_shipper: chỉ SELECT cdr)
   │ AMI Cdr (thời gian thực,     ▼
   │  có thể mất)            cdr-shipper ──HTTPS POST (gọi ra, cụm không mở cổng)──▶ PBX Gateway
   └────────────────────────────────────────────────────────────────────────────────▶   chống trùng theo
                                                                                          (cluster_id, uniqueid, sequence)
```

- **AMI `Cdr` giữ nguyên**: Gateway hiện lịch sử ngay; shipper (trễ vài giây) **bù** những dòng AMI làm mất.
- Bảo đảm **ít nhất một lần** (at-least-once): lỗi thì gửi lại cả lô → Gateway BẮT BUỘC chống trùng.
- Gateway sập bao lâu cũng không mất: dữ liệu chờ trong bảng `cdr`; Gateway sống lại thì shipper gửi bù (đã thử: 1.206 dòng
  trong 3 lô ngay sau khi Gateway sống lại).

## 2. Hợp đồng API — phía PBX Gateway phải làm

**Request** (shipper gửi):
```
POST {GATEWAY_CDR_URL}                      vd https://gateway.local/api/clusters/lab-02/cdr
Authorization: Bearer {CDR_API_KEY}         khóa riêng cho từng cụm
X-Cluster-Id: {CLUSTER_ID}
Content-Type: application/json

{
  "cluster_id": "lab-02",
  "first_id": 1226,                          cdr.id đầu lô
  "last_id": 1725,                           cdr.id cuối lô
  "rows": [                                  ≤ 500 dòng, tăng dần theo id; MỌI cột của bảng cdr
    {"id": 1226, "calldate": "2026-10-22T10:15:03+07:00", "clid": "\"Nguyen Van A\" <155>",
     "src": "155", "dst": "157", "dcontext": "from-internal", "channel": "PJSIP/155-0000001a",
     "dstchannel": "PJSIP/157-0000001b", "lastapp": "Dial", "lastdata": "PJSIP/157,30",
     "duration": 31, "billsec": 27, "disposition": "ANSWERED", "amaflags": "DOCUMENTATION",
     "accountcode": null, "uniqueid": "1792644995.18", "userfield": null, "linkedid": "1792644995.18",
     "peeraccount": null, "sequence": 6, "recordingfile": "20261022-101503_155_157_1792644995.18"},
    ...
  ]
}
```
- `calldate` có múi giờ (ISO 8601). Cột mới thêm vào bảng `cdr` sau này tự xuất hiện trong `rows` → Gateway bỏ qua cột lạ.

**Gateway xử lý:**
1. Xác thực `Authorization` theo khóa của cụm `cluster_id`; sai → `401` (shipper thử lại, ghi log).
2. Lưu từng dòng theo **khóa duy nhất `(cluster_id, uniqueid, sequence)`** — đã có thì bỏ qua (upsert/insert-ignore). Đây cũng là
   khóa của sự kiện AMI `Cdr` (`UniqueID`, `Sequence`) → hai nguồn trộn không trùng (đã kiểm tra khớp). `sequence` đếm lại từ đầu
   khi Asterisk khởi động lại nhưng `uniqueid` chứa thời điểm nên cặp khóa vẫn duy nhất.
3. Commit xong mới trả lời.

**Response:**
```
200 OK
{"acked_id": 1725}      id lớn nhất ĐÃ LƯU CHẮC CHẮN (thường = last_id; lưu được một phần thì trả id cuối đã lưu)
```
- `acked_id` phải nằm trong `[first_id - 1, last_id]`; ngoài khoảng → shipper coi là lỗi, gửi lại.
- Mã khác 200, hết thời gian (15 giây), JSON sai → shipper gửi lại **đúng lô đó** sau 1, 2, 4… tối đa 60 giây.
- Xử lý xong trong vài giây; lô tối đa 500 dòng (~300 KB).

Gateway giả làm đúng hợp đồng để tham khảo/thử: [cdr-shipper/test/fake_gateway.py](../cdr-shipper/test/fake_gateway.py).

## 3. Bật trên cụm

1. Gateway đã có API ở mục 2 và cấp `CDR_API_KEY` cho cụm.
2. `.env`:
   ```
   COMPOSE_PROFILES=shipper
   GATEWAY_CDR_URL=https://<gateway>/api/clusters/<CLUSTER_ID>/cdr
   CLUSTER_ID=lab-02
   CDR_API_KEY=<khóa Gateway cấp>
   CDR_SHIPPER_DB_PASSWORD=<mật khẩu mạnh>
   CDR_SHIP_START=all          # lần đầu: all = gửi toàn bộ lịch sử cũ; now = chỉ từ lúc bật
   ```
3. Tạo user DB (DB đã có dữ liệu thì init không tự chạy):
   ```bash
   docker compose up -d db                     # nạp biến CDR_SHIPPER_DB_* vào container db
   docker compose exec db sh /docker-entrypoint-initdb.d/04-cdr-shipper-user.sh
   docker compose up -d --build
   docker compose logs -f cdr-shipper          # "Đã giao N dòng (id a..b)"
   ```

## 4. Vận hành

| Việc | Cách |
| --- | --- |
| Xem tiến độ | `docker compose logs --tail 20 cdr-shipper`; mốc đã giao: `docker compose exec cdr-shipper cat /state/last_acked_id` so với `select max(id) from cdr` |
| Gateway lỗi lâu | Log `Lỗi: ... thử lại sau Ns`; quá `CDR_SHIP_WARN_MINUTES` (10) phút còn dòng chưa giao → dòng `CẢNH BÁO` |
| Gửi lại toàn bộ (Gateway mất dữ liệu) | `docker compose stop cdr-shipper`, xóa volume `shipperstate` (hoặc ghi `0` vào `/state/last_acked_id`), `start` — Gateway chống trùng |
| Khôi phục DB cụm từ bản sao lưu | Shipper thấy `max(cdr.id)` < mốc → tự gửi lại từ đầu (log `CẢNH BÁO`) |
| Tắt | Bỏ `shipper` khỏi `COMPOSE_PROFILES`, `docker compose up -d --remove-orphans` |

Biến tùy chỉnh: `CDR_SHIP_INTERVAL` (5 giây quét), `CDR_SHIP_BATCH` (500), `CDR_SHIP_SAFETY_LAG` (5 giây), `CDR_SHIP_HTTP_TIMEOUT` (15),
`GATEWAY_CA_FILE` (CA riêng của Gateway), `GATEWAY_TLS_INSECURE=yes` (chỉ lab, Gateway chứng chỉ tự ký).

**Trễ an toàn:** hai cuộc gọi kết thúc cùng lúc có thể ghi xong lệch thứ tự vài mili giây (dòng id nhỏ hiện ra sau dòng id lớn).
Nếu đã gửi qua id lớn thì dòng id nhỏ bị bỏ sót vĩnh viễn → shipper chỉ gửi tới mốc `max(id)` đã ổn định ≥ `CDR_SHIP_SAFETY_LAG` giây.

## 5. Đã thử (Docker cục bộ, 22/10/2026, Gateway giả)

| Tình huống | Kết quả |
| --- | --- |
| Lần chạy đầu (`all`) | Giao đủ 19 dòng cũ |
| Gateway trả 503 trong lúc có 1.206 dòng mới (3 cuộc gọi thật + 1.200 dòng giả lập) | Thử lại 1-2-4-8 giây, mốc đứng yên; Gateway sống lại → giao 500+500+206, tổng khớp `cdr`, 0 trùng |
| Shipper dừng, thêm 300 dòng, chạy lại | Tiếp tục đúng từ mốc đã lưu |
| Gateway chỉ xác nhận nửa lô | Gửi tiếp phần còn lại ngay, 0 trùng |
| User `cdr_shipper` | Đọc được `cdr`; `DELETE` bị từ chối |
| Khóa AMI `Cdr` ↔ bảng `cdr` | Cùng `UniqueID` + `Sequence` |
