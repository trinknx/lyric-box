# Lyric Box

[English](README.md) · **Tiếng Việt**

App cho macOS biến màn hình nền thành màn hiển thị lời bài hát kiểu **COTODAMA Lyric Speaker**: khi bạn phát nhạc trên **Spotify** (app desktop), lời đồng bộ tự hiện bằng chữ chuyển động ngay trên desktop, nằm dưới mọi cửa sổ.

- Không cần đăng nhập Spotify: app đọc bài đang phát từ app Spotify trên máy.
- Lời đồng bộ lấy từ [LRCLIB](https://lrclib.net) và lưu cache, tự chạy theo Spotify. Bài nào LRCLIB chưa có lời đồng bộ thì hiện tên bài và đồ họa động. (Lời trên Spotify lấy từ Musixmatch, không miễn phí, nên có bài Spotify có lời mà ở đây không có.)
- Chỉ có icon trên thanh menu, không có giao diện điều khiển.
- Đang phát → lời hiện dần. Tạm dừng/tắt nhạc → mờ đi, trả lại hình nền gốc.

Viết bằng Swift + Core Animation: app 4.8 MB (dmg 2.9 MB, phần lớn là phông chữ đi kèm), ~50 MB RAM, CPU của app tối đa vài %, chạy trên Apple Silicon và Intel (macOS 13+).

## Cài đặt

Tải **[Lyric-Box-0.4.0.dmg](https://github.com/trinknx/lyric-box/releases/latest)** ở mục Releases.

1. Mở file `.dmg`, kéo **Lyric Box** vào **Applications**.
2. Mở lần đầu: macOS sẽ chặn vì app chưa được Apple ký số. Vào **System Settings → Privacy & Security**, bấm **Open Anyway**. (Hoặc: `xattr -dr com.apple.quarantine "/Applications/Lyric Box.app"`)
3. Phát nhạc trên **app Spotify** (Free hay Premium đều được). Khi macOS hỏi *"Lyric Box muốn điều khiển Spotify"*, bấm **OK**; cho phép thêm *âm thanh từ ứng dụng khác* nếu muốn hiệu ứng theo nhịp.
4. Xong: lời tự hiện trên màn hình nền. Icon trăng khuyết trên thanh menu là menu cài đặt.

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

Thêm `LYRICBOX_SNAPSHOT=/thư/mục` để app tự vẽ 10 ảnh PNG của màn hình lời ngoài màn hình (CARenderer, có cả 3D) trong ~40 giây rồi thoát, để kiểm tra giao diện mà không cần quyền quay màn hình.

**Gửi cho người khác:** bản build chỉ ký ad-hoc, nên lần đầu mở cần **System Settings → Privacy & Security → Open Anyway** (hoặc `xattr -dr com.apple.quarantine "/Applications/Lyric Box.app"`). Muốn mở thẳng không cảnh báo thì cần ký + notarize bằng Apple Developer ID.

### Cách hoạt động

- **Đọc Spotify**: lắng nghe thông báo `com.spotify.client.PlaybackStateChanged` mà Spotify phát ra khi đổi bài / phát / dừng, và cứ 1.5 giây đọc lại vị trí bằng AppleScript chạy trong app (không tạo tiến trình `osascript`).
- **Vẽ**: mỗi chữ cái là một `CALayer` vẽ bằng Core Text. Camera là 3 layer lồng nhau (xoay → zoom → dịch). Mọi chuyển động, kể cả đồ họa nền, là animation Core Animation do render server của macOS chạy; code của app chỉ kiểm tra thời gian lời ~20 lần/giây.
- **Phông**: đi kèm Noto Serif và Noto Sans bản variable (giấy phép SIL Open Font License, `native/Resources/Fonts/OFL.txt`); trục độ đậm và độ rộng cho kiểu thường, đậm và đậm hẹp. Tiếng Nhật dùng Hiragino Mincho / Hiragino Sans. Có thể chọn phông hệ thống (New York / SF Pro) trong menu.
- **Cửa sổ**: tầng ngay dưới desktop (`desktopWindow − 1`), ở mọi Space, click xuyên qua.
- **Theo nhịp** (macOS 14.2+): một Core Audio process tap chỉ nghe các tiến trình của Spotify qua một thiết bị gộp riêng tư. Trên luồng âm thanh, mẫu được rút gọn thành đường bao năng lượng âm trầm; một nhịp là khi năng lượng vọt lên trên mức trung bình gần đây, còn tempo lấy từ tự tương quan của đường bao onset trong ~6 giây gần nhất (chỉ hiện khi đã ổn định). Nhịp được gửi trễ đúng độ trễ của thiết bị phát, để hiệu ứng khớp lúc bạn nghe. Không ghi lại hay lưu âm thanh. Cần quyền "âm thanh từ ứng dụng khác", macOS hỏi ở lần đầu.

### Cấu trúc

```
native/Sources/LyricBox/
  AppDelegate.swift     cửa sổ hình nền, menu bar, cài đặt, phím tắt, snapshot
  SpotifyMonitor.swift  đọc Spotify (thông báo + AppleScript)
  LyricsStore.swift     tải + cache lời từ LRCLIB
  LRC.swift             đọc file LRC, ước lượng thời điểm từng chữ
  Scene.swift           nền, chọn dòng theo thời gian, poster, hiện/ẩn
  Flow.swift            canvas COTODAMA: bố cục khối chữ, camera, hiện từng chữ cái
  Constellation.swift   kiểu chòm sao: ngôi sao, đường nối, trời sao lấp lánh
  Ambient.swift         4 kiểu đồ họa (vòng sóng, dải sóng, lưới chấm, tia sáng)
  WordZoom.swift        kiểu rap: từng chữ một
  AudioTap.swift        nghe âm thanh Spotify, phát hiện nhịp / tempo
  Saver.swift           chế độ bảo vệ màn hình
  SaverBridge.swift     app → Lyric Box.saver
native/Saver/           trình bảo vệ màn hình của macOS (LyricBoxSaverView, cùng engine)
  HotKeys.swift         ⌥⌘[ / ⌥⌘]
```

## Menu trên thanh menu

Menu của app bằng tiếng Anh:

- **Show Lyrics on Desktop**: bật/tắt lời trên màn hình nền
- **Style** (kiểu chữ): Automatic (tự động theo bài) / Calm (êm dịu) / Medium (vừa) / Energetic (sôi động) / Constellation (chòm sao 3D) / Rap / Glitch
- **Font**: Noto Serif / Sans (giống COTODAMA dùng cho chữ Latin và tiếng Việt) hoặc phông hệ thống
- **Beat Sync** (theo nhịp nhạc): Off / Soft (chữ và nền đập theo nhịp) / Strong (thêm dòng chữ nảy); tùy chọn *Flash on Strong Beats* (nháy sáng ở nhịp mạnh của bài sôi động); hiện BPM đo được
- **Screen Saver** (bảo vệ màn hình):
  - Chế độ riêng của Lyric Box: Off / sau 2, 5 hoặc 10 phút không dùng máy, *Only While Spotify Plays* (chỉ khi Spotify đang phát, mặc định bật), *Preview Now* (xem thử). Lời phủ mọi màn hình, nằm trên tất cả cửa sổ; di chuột hoặc bấm phím là trở lại (phím không bị gõ vào ứng dụng bên dưới). Màn hình được giữ sáng khi đang hiện và đang phát nhạc. Nền trong suốt chuyển sang nền tối ở chế độ này.
  - **Install as Mac Screen Saver…**: chép `Lyric Box.saver` vào `~/Library/Screen Savers` và mở cài đặt Screen Saver; chọn **Lyric Box** ở đó. Lời sẽ hiện cả khi macOS chạy trình bảo vệ màn hình, kể cả khi máy đang khóa. Cần để app Lyric Box chạy (app gửi bài đang phát cho trình bảo vệ màn hình). Làm lại sau mỗi lần cập nhật app.
  - **Start Screen Saver When Mac Locks** (mặc định bật, cần cài trình bảo vệ màn hình ở trên): khi khóa máy (`⌃⌘Q`) lúc Spotify đang phát, trình bảo vệ màn hình bật ngay thay vì chờ hết thời gian chờ của macOS, nên lời vẫn chạy trên màn hình khóa. Ứng dụng không vẽ được lên ô nhập mật khẩu.
- **Background** (nền): Dark · Light (acrylic trong) · Transparent — white text · Transparent — black text (hai kiểu trong suốt giữ hình nền của bạn)
- **Display** (màn hình): Main Display, chọn một màn hình, hoặc All Displays
- **Show Song Title**: hiện tên bài
- **Lyrics Offset** (lệch lời): `⌥⌘]` sớm hơn · `⌥⌘[` trễ hơn (0.25s mỗi lần)
- **Search Lyrics Again**: tìm lại lời khi lời sai hoặc LRCLIB quá tải (khi quá tải app cũng tự tìm lại mỗi 30 giây, tối đa 3 lần)
- **Open at Login**: mở cùng macOS

## Hiệu ứng (mô phỏng COTODAMA)

- Lời được **gõ ra từng chữ cái** theo lúc hát, căn trái, cỡ chữ khác nhau.
- **Canvas liên tục**: dòng cũ vẫn ở lại và mờ đi; camera lia, zoom, **xoay 90°** sang dòng mới.
- Thỉnh thoảng hiện mờ chữ sắp hát, hoặc đặt cụm ngắn trong khung đảo màu.
- Tâm trạng theo mật độ chữ: êm dịu (serif mảnh, chậm) · vừa · sôi động (in hoa đậm, nhanh).
- **Chòm sao** (3D): mỗi chữ là một ngôi sao ở một độ sâu riêng, chữ gần to, chữ xa nhỏ. Các sao của dòng hiện mờ trước để thấy hình chòm sao; khi hát tới chữ nào, sao đó sáng lên, một đường nối mọc ra từ sao trước xuyên qua không gian 3D, và chữ được gõ ra bên cạnh. Cả bầu trời đung đưa chậm như đang được kéo bằng tay, chữ gần di chuyển nhiều hơn chữ xa (thị sai), còn chữ luôn quay mặt về phía bạn. Chòm sao mới bay ra từ xa, chòm cũ lùi sâu và mờ đi. Ở chế độ tự động, khoảng một nửa số bài êm dịu dùng kiểu này.
- Bài không có lời: "poster" chữ từ tên bài → ca sĩ → album (đổi mỗi 8s) trên nền đồ họa động (vòng sóng, dải sóng, lưới chấm, tia sáng; mỗi bài một kiểu). Đoạn nhạc dạo giữa bài cũng hiện đồ họa này.

- **Rap**: mỗi lần một chữ thật to ở giữa, bật vào lúc hát còn chữ trước phóng qua, cả dòng hiện nhỏ bên dưới. Chế độ tự động dùng khi lời hát rất dày.
- **Glitch** (rock / điện tử): chữ giật, nhấp nháy và tách bóng màu khi hiện ra và ở nhịp mạnh.
- **Sôi động**: khối chữ nghiêng và xoay vào; hết dòng thì chữ vỡ thành hạt sáng.
- **Vừa**: dòng mới hiện mờ rồi nét căng vào đúng nhịp tiếp theo.
- **Điệp khúc**: các dòng lặp lại trong bài được coi là điệp khúc: chữ nhấn to hơn, zoom nhiều hơn, hiệu ứng nhịp mạnh hơn, và một cú "hit" (lóe sáng + đập) khi điệp khúc bắt đầu.
- **Tâm trạng theo âm thanh**: khi tempo đã ổn định, bài nhanh (≥128 BPM) lên một mức, bài chậm (≤82 BPM) xuống một mức. Chế độ tự động còn dùng chòm sao cho nửa số bài êm dịu và glitch cho một phần ba số bài sôi động.
- **Theo nhịp**: chữ và quầng sáng đập theo nhịp, dòng hiện tại nảy lên kèm co giãn (chế độ mạnh), đồ họa nền phồng lên, bài sôi động có thể nháy sáng ở nhịp mạnh (mặc định tắt).

`legacy-web/` là bản web player đầu tiên (có thanh điều khiển, nạp file nhạc/LRC, 7 kiểu chữ), giữ lại để tham khảo.
