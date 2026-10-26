# IVR — menu bấm phím

Người gọi vào số IVR → nghe lời chào → bấm phím → được chuyển tới máy lẻ / group / IVR khác. Hiện gọi được từ máy lẻ nội bộ;
khi có trunk nhà mạng, số gọi vào (DID) sẽ trỏ tới số IVR.

## 1. Thiết kế

| Thành phần | Ở đâu | Ai quản lý |
| --- | --- | --- |
| Menu (đích của từng phím, đích mặc định, thời gian chờ, số lần nhắc) | **astdb**, khóa `ivr/<số IVR>/...` | **PBX Gateway** qua AMI `DBPut` / `DBDel` / `DBDelTree` — hiệu lực ngay, không reload |
| Lời chào | File `/var/lib/asterisk/ivr/<số IVR>.wav` (volume `astivr`) | Quản trị viên **ghi qua điện thoại**: gọi `*46<số IVR>` |
| Logic chạy menu | `extensions.conf` (nhãn `ivr` trong `[from-internal]` `_X.`) | Repo này |

Số IVR thuộc dải **9000–9999** (quy ước do Gateway kiểm tra). Dialplan tra theo thứ tự: group → **IVR** → máy lẻ → "số không tồn tại".
Một số không được vừa là IVR vừa là máy lẻ/group (Gateway chặn).

## 2. Khóa trong astdb — hợp đồng cho PBX Gateway

| Khóa (family / key) | Bắt buộc | Giá trị | Mặc định |
| --- | --- | --- | --- |
| `ivr/<số>` / `default` | **có** — có khóa này thì số là IVR | Đích khi không bấm hoặc bấm sai quá số lần nhắc | — |
| `ivr/<số>` / `opt/<phím>` | không | Đích của phím `0`–`9` hoặc `*` | — |
| `ivr/<số>` / `timeout` | không | Giây chờ bấm sau lời chào | `5` |
| `ivr/<số>` / `retries` | không | Số lần nhắc lại khi không bấm / bấm sai | `2` |
| `ivr/<số>` / `prompt` | không | Đường dẫn file lời chào **không đuôi** (vd âm thanh có sẵn `demo-instruct`) | `/var/lib/asterisk/ivr/<số>` |
| `ivr/<số>` / `name` | không | Tên hiển thị (Asterisk không dùng) | — |

**Đích** = một số (máy lẻ, group, IVR khác, `*43`...) hoặc `hangup` (chào tạm biệt rồi gác máy). Phím `#` không dùng làm lựa chọn
(Asterisk coi `#` là kết thúc nhập).

AMI (user Gateway có quyền `system`, đã kiểm tra):
```
Action: DBPut          Family: ivr/9000   Key: default   Val: 6000
Action: DBPut          Family: ivr/9000   Key: opt/1     Val: 6000
Action: DBPut          Family: ivr/9000   Key: opt/2     Val: 1055
Action: DBPut          Family: ivr/9000   Key: opt/9     Val: 9001
Action: DBDel          Family: ivr/9000   Key: opt/2                 (bỏ một phím)
Action: DBDelTree      Family: ivr/9000                              (xóa cả IVR)
Action: DBGet          Family: ivr/9000   Key: default               (đọc; liệt kê: Command "database show ivr/9000")
```
Gateway nên kiểm tra: đích tồn tại (máy lẻ/group/IVR), `default` luôn có, không trỏ vòng (Asterisk vẫn tự chặn sau 5 lần chuyển IVR).

## 3. Hành vi khi gọi

1. Nhấc máy, phát lời chào (chưa ghi lời chào → chỉ một tiếng bíp; vẫn bấm phím được).
2. Chờ `timeout` giây. Bấm phím có trong menu → chuyển tới đích.
3. Bấm phím không có → phát "invalid" rồi nhắc lại. Không bấm → nhắc lại. Tối đa `retries` lần nhắc (mặc định tổng 3 lần nghe lời chào).
4. Hết lượt → đích `default`.
5. IVR trỏ tiếp IVR được (menu con); quá 5 lần chuyển IVR trong một cuộc gọi → báo "số không dùng được" và gác máy.

Âm thanh có sẵn ("invalid", "goodbye") là **tiếng Anh** của Asterisk; nội dung tiếng Việt nằm trong lời chào tự ghi
(vd "… bấm sai, xin bấm lại" có thể ghi luôn vào lời chào).

**Lịch sử (cdr / sự kiện AMI `Cdr`):** `dst` = đích cuối cùng (vd `6000`), `lastapp` = `Queue`/`Dial`; đường đi IVR nằm ở
**`userfield`**, dạng `ivr:<số>=<phím>;` nối tiếp, `t` = không bấm/hết lượt. Ví dụ `ivr:9000=9;ivr:9001=1;` = bấm 9 ở 9000 rồi 1 ở 9001.

## 4. Ghi lời chào qua điện thoại

1. Đặt PIN trong `.env`: `IVR_RECORD_PIN=<4-8 số>` → `docker compose up -d` (để trống = tắt tính năng).
2. Từ máy lẻ bất kỳ gọi **`*46<số IVR>`** (vd `*469000`).
3. Nghe "password" → bấm PIN rồi `#`.
4. Nghe bíp → **nói lời chào** → bấm `#` (hoặc im lặng 5 giây) để dừng. Tối đa 3 phút.
5. Asterisk phát lại bản vừa ghi rồi bíp: **bấm 1 = lưu** (thay lời chào cũ, hiệu lực ngay), **2 = ghi lại**, phím khác / không bấm = hủy.

Ghi ở nơi yên tĩnh, nói rõ, nên dùng softphone/tai nghe tốt (âm thanh lưu đúng như nghe được qua cuộc gọi, 8 kHz).
Lời chào nằm trong volume `astivr` và có trong bản sao lưu (`astivr.tar.gz`, [sao-luu.md](sao-luu.md)).

## 5. Đã thử (Docker cục bộ, 26/10/2026)

Menu tạo qua AMI `DBPut` bằng user Gateway; người gọi giả lập bằng kênh Local + `SendDTMF`:

| Tình huống | Kết quả |
| --- | --- |
| Bấm 2 | Sang máy lẻ đích |
| Không bấm (timeout 2 giây, retries 2) | Nghe lời chào 3 lần → đích mặc định |
| Bấm phím không có (5) | "invalid" → nhắc lại |
| Bấm 9 → menu con 9001 → bấm 1 | Sang `*44`; `userfield` = `ivr:9000=9;ivr:9001=1;` |
| IVR tự trỏ vào chính nó | Dừng ở lần thứ 6, "ss-noservice" |
| `*469000`: PIN → ghi → nghe lại → bấm 1 | Lưu `9000.wav`; gọi 9000 phát đúng lời chào mới |
| Sao lưu | `MANIFEST` có `ivrs=3`, `astivr.tar.gz` có `9000.wav` |
