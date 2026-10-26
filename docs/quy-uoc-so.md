# Quy ước số mới — định tuyến theo tra cứu (21/10/2026)

Thay quy ước "3 chữ số, đầu số quyết định loại" (08/10/2026). Thay đổi nằm ở **3 repo**: `pbx-node` (file này),
`pbx-gateway`, `admin-pbx-ui`. Tài liệu này ghi **vì sao đổi, đổi gì ở từng repo, đã kiểm tra gì, cách áp dụng**.

## 1. Vấn đề và cách giải

Quy ước cũ: dialplan `_[1-5]XX` → máy lẻ, `_[6-9]XX` → group. Hai giới hạn:
- Chỉ **500 máy lẻ, 400 group**. Muốn thêm phải sửa dialplan + Gateway + UI cùng lúc.
- Đầu số gánh 2 việc: vừa để **Asterisk định tuyến**, vừa để **người đọc biết loại**. Cho tự do số thì mất cái sau.

Cách giải: **tách hai việc đó ra.**

| Việc | Trước | Sau |
| --- | --- | --- |
| Asterisk định tuyến | Theo mẫu đầu số | **Tra cứu**: số là group (`QUEUE_EXISTS`) → Queue; là máy lẻ (`PJSIP_ENDPOINT`) → Dial; không có → "số không tồn tại". Không biết gì về dải số |
| Người đọc biết loại số | Theo đầu số (cứng trong 3 repo) | **Quy ước dải** do Gateway kiểm tra khi tạo, cấu hình được (`GW_NUMBERING_*`), UI đọc từ `GET /numbering` |
| Biết Web hay Softphone | Không có (vẫn đúng: không theo số) | **Nhãn trên UI**: Softphone / Web / AI / Group ở mọi nơi hiện số |

## 2. Quy ước mặc định

| Dải | Dùng cho | Sức chứa |
| --- | --- | --- |
| **1000–5999** | Máy lẻ — mọi loại (Softphone, Web, AI) | 5.000 |
| **6000–8999** | Group | 3.000 |
| **9000–9999** | **IVR** (menu bấm phím, 26/10/2026 — [ivr.md](ivr.md)); không tạo máy lẻ / group trong dải này | 1.000 |
| 100–599 / 600–999 | **Dải cũ, vẫn dùng** — máy đang có không phải đánh số lại | 500 / 400 |
| `*43` `*44` `*45` | Số thử (âm thanh, phím bấm, thử tải) | — |

Định dạng số: chỉ chữ số, **không bắt đầu bằng 0**, 2–6 chữ số (`0100` khác `100` — chặn để khỏi nhầm).
Đổi dải: sửa `.env` của Gateway (mục 4), **không** sửa Asterisk. Dải không được chồng nhau (Gateway từ chối khởi động).

## 3. pbx-node (repo này)

| File | Thay đổi |
| --- | --- |
| `asterisk/conf/extensions.conf` | `[from-internal]`: 2 mẫu `_[1-5]XX` / `_[6-9]XX` → 1 mẫu `_X.` tra cứu (dưới). `*43/*44/*45` giữ nguyên (mẫu cụ thể được ưu tiên). Ghi chú đầu file viết lại |
| `CLAUDE.md` | Dòng "Quy ước số" và "Context" trong bảng quyết định |
| `README.md`, `docs/luu-y-trien-khai.md` | Bỏ nhắc dải 3 chữ số |

```
exten => _X.,1,NoOp(Goi ${EXTEN} tu ${CALLERID(num)})
 same => n,GotoIf($[${QUEUE_EXISTS(${EXTEN})}]?group)                 ; có group số này?
 same => n,GotoIf($["${PJSIP_ENDPOINT(${EXTEN},context)}" != ""]?maule) ; có máy lẻ số này?
 same => n,Progress()                                                  ; không có: báo bằng âm thanh sớm (183),
 same => n,Playback(ss-noservice,noanswer)                             ; KHÔNG nhấc máy -> lịch sử ghi "không thành công"
 same => n,Hangup(1)
 same => n(maule),...Gosub(sub-record)...Dial(PJSIP/${EXTEN},30)       ; như cũ
 same => n(group),...Answer()...Gosub(sub-record)...Queue(${EXTEN},,,,60) ; như cũ
```

Điểm cần biết:
- **Group thắng nếu lỡ trùng số** với máy lẻ. Gateway chặn trùng (mục 4) nên bình thường không xảy ra.
- Mọi nhánh nằm trong **cùng một extension** (chỉ nhảy nhãn) → CDR ghi đúng `dst` / `lastapp` như trước (đã kiểm tra, mục 6).
- Gọi số không tồn tại sinh 1 dòng `WARNING func_pjsip_endpoint.c: Failed to retrieve information for endpoint '4321'` — bình thường.
- Sau này thêm gọi ra ngoài (vd `_0X.` qua trunk): mẫu cụ thể hơn được Asterisk ưu tiên trước `_X.`, không phải sửa khối này.
- Chi phí: 2 lần tra cứu trong bộ nhớ mỗi cuộc gọi — không ảnh hưởng chịu tải.

## 4. pbx-gateway

| File | Thay đổi |
| --- | --- |
| `rule/NumberingRules.java` | Viết lại: dải số **cấu hình được** (`Config`, `Range`), kiểm tra chồng nhau, thêm dải dành riêng, `NUMBER_REGEX`. Giữ API tĩnh cũ (`isExtensionNumber`, `validateGroup`, `isInternalNumber`...) nên `CallAssembler`, `SyncService` không phải sửa logic |
| `config/NumberingConfig.java` (mới) | Đọc `pbx.numbering.*` lúc khởi động, nạp vào `NumberingRules`, log dải đang dùng; dải sai → không khởi động |
| `controller/NumberingController.java`, `dto/NumberingDtos.java` (mới) | `GET /api/v1/numbering` (scope ACCOUNT_READ) — UI và service khác đọc quy ước |
| `service/GroupService.java` | Tạo group: chặn số **đang là máy lẻ** (Gateway DB + cụm qua ARI) → 409 `NUMBER_USED_BY_EXTENSION`. Thêm `requireNotGroup` cho ExtensionService |
| `service/ExtensionService.java` | Tạo máy lẻ: gọi `groups.requireNotGroup` → 409 `NUMBER_USED_BY_GROUP` (Gateway DB + cụm qua AMI) |
| `asterisk/AmiQueueWriter.java` | Xóa group: `QueueReload` **riêng group đó** thay vì nạp lại toàn bộ (mục 6: 17 ms thay vì ~3 giây ở 400 group) |
| `dto/ExtensionDtos.java`, `dto/GroupDtos.java` | `@Pattern` từ `\d{3}` → `NumberingRules.NUMBER_REGEX`; mô tả Swagger |
| `service/SyncService.java`, `rule/CallAssembler.java` | Câu báo / chú thích theo dải cấu hình |
| `application.yml`, `.env.example` | `pbx.numbering.extension-ranges / group-ranges / reserved-ranges` ← `GW_NUMBERING_*` |
| Test: `NumberingRulesTest` (viết lại), `CallAssemblerTest` | Thêm: 4 chữ số, số 0 đầu, dải dành riêng, cấu hình riêng, cấu hình sai/chồng nhau. `9000` giờ là số nội bộ (dành riêng) → test "gọi ra" đổi sang số ngoài |
| `CLAUDE.md`, `README.md`, `http/buoc3-*.http`, `postman/*.json` | Quy ước mới, `GET /numbering`, mã lỗi mới |

Biến môi trường (đều có mặc định, không đặt cũng chạy):
```
GW_NUMBERING_EXTENSION_RANGES=1000-5999,100-599
GW_NUMBERING_GROUP_RANGES=6000-8999,600-999
GW_NUMBERING_RESERVED_RANGES=9000-9999
```
Khi đã chuyển hết máy sang 4 chữ số: bỏ `100-599` / `600-999` khỏi 2 biến đầu. Máy cũ vẫn gọi được (Asterisk không
xét dải), chỉ là không tạo thêm số 3 chữ số được nữa và đồng bộ sẽ bỏ qua số ngoài dải.

Mã lỗi mới: `409 NUMBER_USED_BY_GROUP` (tạo máy lẻ trùng số group), `409 NUMBER_USED_BY_EXTENSION` (ngược lại).
Với dải mặc định không chồng nhau, hai lỗi này chỉ gặp khi đổi dải theo thời gian (số cũ còn đó) hoặc cụm có đối tượng
Gateway chưa quản lý — là lưới an toàn để không bao giờ có máy lẻ "biến mất" vì trùng số group.

## 5. admin-pbx-ui

| File | Thay đổi |
| --- | --- |
| `src/api/types.ts`, `src/api/endpoints.ts` | `NumberingConfig`, `numberingApi.get()` |
| `src/hooks/useNumbering.ts` (mới) | Đọc `GET /numbering` (cache 30 phút); Gateway cũ chưa có API → dùng mặc định |
| `src/utils/numbering.ts` | Bỏ dải cứng; validator nhận cấu hình (`extensionNumberRule(cfg)`, `groupNumberRule(cfg)`), câu báo giống Gateway; `suggestNumber`, `byNumber`/`sortByNumber`; nhãn loại đổi "Người" → **"Softphone"** cho rõ; `EXT_TYPE_PROFILE` HUMAN/AI transport sửa thành "tự chọn (UDP/TCP/TLS)" cho khớp Gateway (đã đổi từ 13/10) |
| `src/hooks/useNumberDirectory.ts` (mới) | Tra số → loại (máy lẻ + loại / group) theo danh sách của server, dùng chung cache |
| `src/components/tags.tsx` | `ExtTypeTag` (Softphone xám ☎ / Web xanh 🌐 / AI tím 🤖), `GroupTag` (vàng), `NumberWithType` |
| `src/pages/extensions/ExtensionsPage.tsx` | Form: dải từ Gateway, **gợi ý số trống** ("dùng 1002", tránh cả số chỉ có trên cụm), tối đa 6 ký tự; bảng: cột Loại dùng `ExtTypeTag`, **sắp theo giá trị số** |
| `src/pages/groups/GroupsPage.tsx` | Dải từ Gateway; chọn thành viên hiện loại ("1011 · Web · Tên"); sắp theo số |
| `src/pages/calls/CallsPage.tsx` | Cột Từ / Đến / Người nghe hiện số **kèm nhãn** Softphone / Web / AI / Group / Số thử |
| `src/pages/accounts/AccountsPage.tsx`, `src/portal/MyExtensionsPage.tsx` | Sắp máy lẻ theo số |
| `mock/server.mjs` | `GET /numbering`, kiểm tra dải mới, 2 mã lỗi trùng số |
| `CLAUDE.md` | Quy ước dùng `useNumbering`, nhãn, `byNumber` |

Vì sao phải sắp theo số: khi `100` và `1000` lẫn nhau, sắp kiểu chuỗi ra `100, 1000, 1001, 101...` — rất rối.

## 6. Đã kiểm tra (21/10/2026)

Môi trường thử: Asterisk 20.6 (đúng gói Ubuntu 24.04 của image), SIPp làm điện thoại, Gateway build từ code đã sửa +
PostgreSQL, UI chạy Vite + Chromium headless.

**pbx-node — cuộc gọi SIP thật, đọc sự kiện AMI `Cdr` (cái Gateway lưu lịch sử):**

| Gọi tới | Kết quả | CDR |
| --- | --- | --- |
| `1001` máy lẻ 4 chữ số | Nghe máy | dst=1001, app=Dial, ANSWERED, dstchannel PJSIP/1001 |
| `6001` group 4 chữ số | Thành viên 1001 nghe | dst=6001, app=Queue, ANSWERED |
| `103` máy lẻ 3 chữ số cũ | Nghe máy | dst=103, app=Dial, ANSWERED |
| `600` group cũ | Thành viên 103 nghe | dst=600, app=Queue, ANSWERED |
| `4321` không tồn tại | 404, không nhấc máy | dst=4321, NO ANSWER (không bị tính là thành công) |
| `150` máy web cũ | Nhận đúng là máy lẻ (đọc được `webrtc=yes`) | — |

QueueReload riêng một group đã xóa khỏi file: group đó biến mất, 17 ms, 399 group còn lại giữ nguyên.

**pbx-gateway:** biên dịch + **65/65 unit test đạt** (JDK 21). Chạy thật với cụm thử:
`GET /numbering` đúng; tạo máy lẻ `1010` → SYNCED trên cụm; `6010` / `9001` → 400 đúng câu báo; `0100` → 400 định dạng;
`155` (có sẵn trên cụm) → 409 như cũ; group `6010` thành viên `1010` → có trên Asterisk; group `1020` → 400;
group `6500` khi cụm có máy lẻ 6500 → 409 `NUMBER_USED_BY_EXTENSION`; máy lẻ `1500` khi cụm có group 1500 → 409
`NUMBER_USED_BY_GROUP`; xóa group `6010` → 204, Asterisk "No such queue", group khác còn nguyên; lịch sử 3 cuộc gọi
đúng chiều / kết quả.

**admin-pbx-ui:** `tsc` + `vite build` đạt. Trình duyệt với Gateway thật: 16/16 bước + tìm kiếm 3/3 — nhãn
Softphone / Web / AI, form hiện dải từ Gateway, gợi ý số trống không trùng cụm, 6010 / 9001 / 0100 báo đúng lỗi, tạo máy
bằng số gợi ý, group từ chối 1020, chọn thành viên hiện loại, lịch sử có nhãn Softphone / Group, sắp theo số, mobile
không cuộn ngang, không lỗi JS. Mock server: `GET /numbering` và 5 trường hợp tạo đều đúng.

**Chưa kiểm tra:** chưa chạy trên lab-02 / cụm thật; chưa gọi từ softphone/trình duyệt thật vào số 4 chữ số (SIPp thay
thế). (22/10/2026: bỏ loại máy AI và context `from-ai` — chỉ còn máy softphone và máy web.)

## 7. Áp dụng

Thứ tự: **pbx-node trước** (dialplan mới chạy được cả số cũ), rồi Gateway, rồi UI.

```bash
# pbx-node (mỗi cụm) — restart Asterisk = rớt cuộc gọi đang diễn ra, làm ngoài giờ
git pull && docker compose up -d --build
docker compose exec asterisk asterisk -rx "dialplan show from-internal"     # thấy '_X.' và *43 *44 *45
# gọi thử: 1 máy lẻ cũ, 1 group cũ, 1 số không tồn tại (nghe "not in service")

# pbx-gateway
docker compose up -d --build
docker compose logs gateway | grep "Quy ước số"                             # in dải đang dùng
curl -s -H "X-Api-Key: <key>" http://localhost:8080/api/v1/numbering

# admin-pbx-ui
npm run build   # rồi triển khai như thường lệ
```

Lưu ý: **Gateway mới + pbx-node cũ** vẫn tạo được máy 4 chữ số, nhưng dialplan cũ không gọi tới được → luôn cập nhật
pbx-node trước.
