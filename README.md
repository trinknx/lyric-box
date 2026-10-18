# Lyric Box

App cho macOS biến màn hình nền thành màn hiển thị lời bài hát kiểu **COTODAMA Lyric Speaker**: khi bạn phát nhạc trên **Spotify** (app desktop), lời đồng bộ tự hiện bằng chữ chuyển động ngay trên desktop, nằm dưới mọi cửa sổ.

- Không cần đăng nhập Spotify: app đọc bài đang phát từ app Spotify trên máy.
- Lời đồng bộ lấy từ [LRCLIB](https://lrclib.net) và lưu cache.
- Chỉ có icon trên thanh menu, không có giao diện điều khiển.
- Đang phát → lời hiện dần. Tạm dừng/tắt nhạc → mờ đi, trả lại hình nền gốc.

Viết bằng Swift + Core Animation: app 844 KB (dmg 568 KB), ~50 MB RAM, CPU của app ~0.2%, chạy trên Apple Silicon và Intel (macOS 13+).

## Build

```bash
cd native
./scripts/build.sh          # → native/build/Lyric Box.app
./scripts/build.sh --dmg    # + native/build/Lyric Box.dmg
open "build/Lyric Box.app"
```

Cần Xcode (hoặc Command Line Tools) có Swift 6.

Lần đầu phát nhạc, macOS hỏi *"Lyric Box muốn điều khiển Spotify"*, hãy bấm **OK**.
Nếu lỡ từ chối: **System Settings → Privacy & Security → Automation → Lyric Box**, bật Spotify. Nếu Lyric Box không có trong danh sách:

```bash
tccutil reset AppleEvents io.bamboosoft.lyricbox
```

Thử không cần Spotify:

```bash
LYRICBOX_PREVIEW=1 "native/build/Lyric Box.app/Contents/MacOS/LyricBox"          # bài giả lập
LYRICBOX_PREVIEW=nolyrics "native/build/Lyric Box.app/Contents/MacOS/LyricBox"   # bài không lời
```

Thêm `LYRICBOX_SNAPSHOT=/thư/mục` để app tự chụp 10 ảnh PNG của màn hình lời trong ~40 giây rồi thoát (kiểm tra giao diện mà không cần quyền quay màn hình).

**Gửi cho người khác:** bản build chỉ ký ad-hoc, nên lần đầu mở cần **System Settings → Privacy & Security → Open Anyway** (hoặc `xattr -dr com.apple.quarantine "/Applications/Lyric Box.app"`). Muốn mở thẳng không cảnh báo thì cần ký + notarize bằng Apple Developer ID.

### Cách hoạt động

- **Đọc Spotify**: lắng nghe thông báo `com.spotify.client.PlaybackStateChanged` mà Spotify phát ra khi đổi bài / phát / dừng, và cứ 1.5 giây đọc lại vị trí bằng AppleScript chạy trong app (không tạo tiến trình `osascript`).
- **Vẽ**: mỗi chữ cái là một `CALayer` vẽ bằng Core Text. Camera là 3 layer lồng nhau (xoay → zoom → dịch). Mọi chuyển động, kể cả đồ họa nền, là animation Core Animation do render server của macOS chạy; code của app chỉ kiểm tra thời gian lời ~20 lần/giây.
- **Phông**: New York (serif) và SF Pro (đậm / condensed) có sẵn trong macOS, hỗ trợ đủ tiếng Việt.
- **Cửa sổ**: tầng ngay dưới desktop (`desktopWindow − 1`), ở mọi Space, click xuyên qua.

### Cấu trúc

```
native/Sources/LyricBox/
  AppDelegate.swift     cửa sổ hình nền, menu bar, cài đặt, phím tắt, snapshot
  SpotifyMonitor.swift  đọc Spotify (thông báo + AppleScript)
  LyricsStore.swift     tải + cache lời từ LRCLIB
  LRC.swift             đọc file LRC, ước lượng thời điểm từng chữ
  Scene.swift           nền, chọn dòng theo thời gian, poster, hiện/ẩn
  Flow.swift            canvas COTODAMA: bố cục khối chữ, camera, hiện từng chữ cái
  Ambient.swift         4 kiểu đồ họa (vòng sóng, dải sóng, lưới chấm, tia sáng)
  HotKeys.swift         ⌥⌘[ / ⌥⌘]
```

## Menu trên thanh menu

- **Hiện lời trên màn hình nền**: bật/tắt
- **Kiểu chữ**: COTODAMA tự động theo bài / êm dịu / vừa / sôi động
- **Nền**: Tối · Sáng (acrylic trong) · Trong suốt chữ trắng · Trong suốt chữ đen (giữ hình nền của bạn)
- **Màn hình**: màn hình chính, chọn màn hình, hoặc tất cả
- **Lệch lời**: `⌥⌘]` lời sớm hơn · `⌥⌘[` lời trễ hơn (0.25s mỗi lần)
- **Tìm lại lời** / **Chọn file .lrc cho bài này…** khi LRCLIB không có hoặc sai lời
- **Mở cùng macOS**

## Hiệu ứng (mô phỏng COTODAMA)

- Lời được **gõ ra từng chữ cái** theo lúc hát, căn trái, cỡ chữ khác nhau.
- **Canvas liên tục**: dòng cũ vẫn ở lại và mờ đi; camera lia, zoom, **xoay 90°** sang dòng mới.
- Thỉnh thoảng hiện mờ chữ sắp hát, hoặc đặt cụm ngắn trong khung đảo màu.
- Tâm trạng theo mật độ chữ: êm dịu (serif mảnh, chậm) · vừa · sôi động (in hoa đậm, nhanh).
- Bài không có lời: "poster" chữ từ tên bài → ca sĩ → album (đổi mỗi 8s) trên nền đồ họa động (vòng sóng, dải sóng, lưới chấm, tia sáng; mỗi bài một kiểu). Đoạn nhạc dạo giữa bài cũng hiện đồ họa này.

Giới hạn: Spotify không cho truy cập luồng âm thanh, nên đồ họa không theo nhịp thật.

`legacy-web/` là bản web player đầu tiên (có thanh điều khiển, nạp file nhạc/LRC, 7 kiểu chữ), giữ lại để tham khảo.
