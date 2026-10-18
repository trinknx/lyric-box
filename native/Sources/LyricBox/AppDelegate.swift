import AppKit
import Carbon
import Metal
import ServiceManagement
import UniformTypeIdentifiers

extension NSScreen {
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}

/// Borderless window just below the desktop icons, on every Space, click-through.
final class WallpaperWindow: NSWindow {
    let scene: LyricScene

    init(screen: NSScreen, attach: Bool = true) {
        scene = LyricScene(size: screen.frame.size, backing: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        if attach { view.layer?.addSublayer(scene.root) }
        contentView = view
        setFrame(screen.frame, display: true)
        orderFrontRegardless()
    }

    func fit(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
        scene.layout(size: screen.frame.size, backing: screen.backingScaleFactor)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, enabled: Bool = true, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        state = checked ? .on : .off
        isEnabled = enabled
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { handler() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let settings = Settings.shared
    private let spotify = SpotifyMonitor()
    private let store = LyricsStore()
    private var windows: [CGDirectDisplayID: WallpaperWindow] = [:]
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var pauseWork: DispatchWorkItem?
    private var lyricsStatus = ""                 // "", loading, found, missing
    private var lyrics: (id: String, lrc: String?)?

    // LYRICBOX_PREVIEW=1 (or =nolyrics) → fake song, for testing without Spotify
    private let preview = ProcessInfo.processInfo.environment["LYRICBOX_PREVIEW"]
    private var previewTrack: Track?
    private let previewStart = CACurrentMediaTime()

    private var track: Track? { preview != nil ? previewTrack : spotify.track }
    private var playing: Bool { preview != nil ? true : spotify.playing }
    private var position: Double {
        preview != nil ? (CACurrentMediaTime() - previewStart).truncatingRemainder(dividingBy: 50) : spotify.position
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Self.trayIcon()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu

        Fonts.register()
        Fonts.useNoto = settings.fontSet == .noto
        settings.onChange = { [weak self] k in self?.settingChanged(k) }
        syncWindows()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)

        HotKeys.install()
        HotKeys.register(id: 1, keyCode: kVK_ANSI_RightBracket, modifiers: cmdKey | optionKey) { [weak self] in self?.settings.offset += 0.25 }
        HotKeys.register(id: 2, keyCode: kVK_ANSI_LeftBracket, modifiers: cmdKey | optionKey) { [weak self] in self?.settings.offset -= 0.25 }

        if let preview {
            startPreview(noLyrics: preview == "nolyrics")
        } else {
            spotify.onTrack = { [weak self] t in self?.trackChanged(t) }
            spotify.onState = { [weak self] in self?.stateChanged() }
            spotify.start()
        }

        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let dir = ProcessInfo.processInfo.environment["LYRICBOX_SNAPSHOT"] { scheduleSnapshots(dir) }
    }

    // MARK: playback → scenes

    private var scenes: [LyricScene] { windows.values.map { $0.scene } }

    private func tick() {
        let t = position + settings.offset
        let p = playing
        for s in scenes { s.tick(time: t, playing: p) }
    }

    private func stateChanged() {
        pauseWork?.cancel()
        if playing {
            scenes.forEach { $0.setActive(true) }
        } else {
            // keep lyrics up briefly so a quick pause doesn't flash the wallpaper
            let w = DispatchWorkItem { [weak self] in self?.scenes.forEach { $0.setActive(false) } }
            pauseWork = w
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: w)
        }
    }

    private func trackChanged(_ t: Track?) {
        lyrics = nil
        lyricsStatus = t == nil ? "" : "loading"
        scenes.forEach { $0.setTrack(t) }
        guard let t else { return }
        loadLyrics(t, refresh: false)
    }

    private func loadLyrics(_ t: Track, refresh: Bool) {
        lyricsStatus = "loading"
        store.lyrics(for: t, refresh: refresh) { [weak self] lrc in
            guard let self, self.track?.id == t.id else { return }
            self.applyLyrics(lrc, for: t)
        }
    }

    private func applyLyrics(_ lrc: String?, for t: Track) {
        lyrics = (t.id, lrc)
        lyricsStatus = lrc == nil ? "missing" : "found"
        scenes.forEach { $0.setLyrics(lrc, for: t.id, duration: t.duration) }
    }

    private func startPreview(noLyrics: Bool) {
        let t = Track(id: "preview", name: "Chữ Bay Trong Đêm", artist: "Lyric Box · Preview", album: "Đêm Thành Phố", duration: 50)
        previewTrack = t
        trackChanged(nil)
        scenes.forEach { $0.setTrack(t) }
        applyLyrics(noLyrics ? nil : """
        [00:03.00]Đêm nay thành phố như đang ngủ quên
        [00:08.00]Chỉ còn tiếng nhạc khẽ gọi tên em
        [00:13.00]Từng con chữ bay trong ánh đèn
        [00:18.00]Rơi vào tim như những vì sao
        [00:23.00]
        [00:27.50]Hát lên đi
        [00:30.00]Cho đêm dài thêm sáng
        [00:32.50]Hát lên đi
        [00:35.00]Để lời ca ngân vang mãi
        [00:40.00]Let the words dance in the light
        [00:46.00]
        """, for: t)
        scenes.forEach { $0.setActive(true) }
    }

    // MARK: windows

    private func targetScreens() -> [NSScreen] {
        guard settings.enabled else { return [] }
        let all = NSScreen.screens
        switch settings.display {
        case "all": return all
        case "primary": return Array(all.prefix(1))
        default: return [all.first { String($0.displayID) == settings.display } ?? all[0]]
        }
    }

    private func syncWindows() {
        let wanted = targetScreens()
        let ids = Set(wanted.map { $0.displayID })
        for (id, w) in windows where !ids.contains(id) {
            w.orderOut(nil)
            windows[id] = nil
        }
        for s in wanted {
            if let w = windows[s.displayID] {
                w.fit(s)
                continue
            }
            // snapshot mode renders the scene offscreen instead (CARenderer needs it detached)
            let w = WallpaperWindow(screen: s, attach: ProcessInfo.processInfo.environment["LYRICBOX_SNAPSHOT"] == nil)
            configure(w.scene)
            windows[s.displayID] = w
        }
    }

    private func configure(_ scene: LyricScene) {
        scene.theme = settings.theme
        scene.moodSetting = settings.mood
        scene.showCaption = settings.caption
        scene.setTrack(track)
        if let lyrics, let t = track, lyrics.id == t.id { scene.setLyrics(lyrics.lrc, for: t.id, duration: t.duration) }
        scene.setActive(playing)
    }

    @objc private func screensChanged() { syncWindows() }

    private func settingChanged(_ k: String) {
        switch k {
        case "enabled", "display": syncWindows()
        case "theme": scenes.forEach { $0.theme = settings.theme }
        case "mood": scenes.forEach { $0.moodSetting = settings.mood }
        case "caption": scenes.forEach { $0.showCaption = settings.caption }
        case "offset": scenes.forEach { $0.reset() }
        case "fontSet":
            Fonts.useNoto = settings.fontSet == .noto
            scenes.forEach { $0.reset() }
        default: break
        }
    }

    // MARK: menu bar

    private func statusText() -> String {
        if preview != nil { return "▶︎ Preview" }
        switch spotify.status {
        case .denied: return "⚠︎ Chưa được phép đọc Spotify"
        case .notInstalled: return "Chưa cài app Spotify"
        case .notRunning: return "Spotify chưa mở"
        case .idle: return "Spotify chưa phát nhạc"
        case .ok:
            guard let t = spotify.track else { return "Spotify chưa phát nhạc" }
            var s = "\(t.name) — \(t.artist)"
            if s.count > 48 { s = String(s.prefix(47)) + "…" }
            return (spotify.playing ? "▶︎ " : "❚❚ ") + s
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let info = NSMenuItem(title: statusText(), action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        if track != nil, let text = ["loading": "Đang tìm lời…", "found": "Đã có lời đồng bộ", "missing": "Không tìm thấy lời đồng bộ"][lyricsStatus] {
            let l = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            l.isEnabled = false
            menu.addItem(l)
        }
        if spotify.status == .denied {
            menu.addItem(ActionItem("Mở cài đặt quyền Automation…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Hiện lời trên màn hình nền", checked: settings.enabled) { [weak self] in self?.settings.enabled.toggle() })
        menu.addItem(.separator())

        let mood = NSMenu()
        for m in MoodSetting.allCases {
            mood.addItem(ActionItem(m.title, checked: settings.mood == m) { [weak self] in self?.settings.mood = m })
        }
        menu.addItem(submenu("Kiểu chữ", mood))

        let fonts = NSMenu()
        for f in FontSet.allCases {
            fonts.addItem(ActionItem(f.title, checked: settings.fontSet == f) { [weak self] in self?.settings.fontSet = f })
        }
        menu.addItem(submenu("Phông chữ", fonts))

        let theme = NSMenu()
        for t in Theme.allCases {
            theme.addItem(ActionItem(t.title, checked: settings.theme == t) { [weak self] in self?.settings.theme = t })
        }
        menu.addItem(submenu("Nền", theme))

        let disp = NSMenu()
        disp.addItem(ActionItem("Màn hình chính", checked: settings.display == "primary") { [weak self] in self?.settings.display = "primary" })
        let screens = NSScreen.screens
        if screens.count > 1 {
            for (i, s) in screens.enumerated() {
                let id = String(s.displayID)
                let name = "Màn hình \(i + 1) (\(Int(s.frame.width))×\(Int(s.frame.height)))\(i == 0 ? " — chính" : "")"
                disp.addItem(ActionItem(name, checked: settings.display == id) { [weak self] in self?.settings.display = id })
            }
            disp.addItem(ActionItem("Tất cả màn hình", checked: settings.display == "all") { [weak self] in self?.settings.display = "all" })
        }
        menu.addItem(submenu("Màn hình", disp))
        menu.addItem(ActionItem("Hiện tên bài", checked: settings.caption) { [weak self] in self?.settings.caption.toggle() })

        let off = NSMenu()
        off.addItem(ActionItem("Lời hiện sớm hơn 0.25s   ⌥⌘]") { [weak self] in self?.settings.offset += 0.25 })
        off.addItem(ActionItem("Lời hiện trễ hơn 0.25s   ⌥⌘[") { [weak self] in self?.settings.offset -= 0.25 })
        off.addItem(ActionItem("Đặt lại") { [weak self] in self?.settings.offset = 0 })
        menu.addItem(submenu(String(format: "Lệch lời (%@%.2fs)", settings.offset > 0 ? "+" : "", settings.offset), off))

        menu.addItem(.separator())
        let has = track != nil
        menu.addItem(ActionItem("Tìm lại lời bài này", enabled: has) { [weak self] in
            if let self, let t = self.track { self.loadLyrics(t, refresh: true) }
        })
        menu.addItem(ActionItem("Chọn file .lrc cho bài này…", enabled: has) { [weak self] in self?.pickLrc() })
        menu.addItem(.separator())
        let login = SMAppService.mainApp
        menu.addItem(ActionItem("Mở cùng macOS", checked: login.status == .enabled) {
            if login.status == .enabled { try? login.unregister() } else { try? login.register() }
        })
        menu.addItem(ActionItem("Thoát Lyric Box") { NSApp.terminate(nil) })
    }

    private func submenu(_ title: String, _ sub: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    private func pickLrc() {
        guard let t = track else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.title = "Chọn file lời cho “\(t.name)”"
        panel.allowedContentTypes = [UTType(filenameExtension: "lrc") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let lrc = try? String(contentsOf: url, encoding: .utf8) else { return }
        store.set(t, lrc)
        applyLyrics(lrc, for: t)
    }

    /// Crescent, like the COTODAMA mark.
    private static func trayIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: 1.8, y: 1.8, width: 14.4, height: 14.4)).fill()
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            NSBezierPath(ovalIn: NSRect(x: 5.76, y: 5.4, width: 10.8, height: 10.8)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: debug snapshots (LYRICBOX_SNAPSHOT=/some/dir) — renders the scene to PNGs

    private func scheduleSnapshots(_ dir: String) {
        let times: [Double] = [2.5, 5.5, 9, 12.5, 16, 20, 25, 29, 33, 41]
        for (i, t) in times.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { [weak self] in
                self?.snapshot(URL(fileURLWithPath: dir).appendingPathComponent(String(format: "snap-%02d.png", i)))
                if i == times.count - 1 { NSApp.terminate(nil) }
            }
        }
    }

    private var snapRenderer: (CARenderer, MTLTexture, MTLCommandQueue)?

    /// Renders the scene with CARenderer (Metal) so 3D transforms and perspective are included.
    private func snapshot(_ url: URL) {
        guard let w = windows.values.first, let device = MTLCreateSystemDefaultDevice() else { return }
        let root = w.scene.root
        let W = Int(root.bounds.width), H = Int(root.bounds.height)
        if snapRenderer == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: W, height: H, mipmapped: false)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .managed
            guard let tex = device.makeTexture(descriptor: desc), let queue = device.makeCommandQueue() else { return }
            let r = CARenderer(mtlTexture: tex, options: [kCARendererMetalCommandQueue: queue])
            r.layer = root
            r.bounds = root.bounds
            snapRenderer = (r, tex, queue)
        }
        guard let (r, tex, queue) = snapRenderer else { return }
        r.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        r.addUpdate(r.bounds)
        r.render()
        r.endFrame()
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else { return }
        blit.synchronize(resource: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: W * H * 4)
        tex.getBytes(&bytes, bytesPerRow: W * 4, from: MTLRegionMake2D(0, 0, W, H), mipmapLevel: 0)
        // CARenderer's texture is bottom-up: flip rows
        var flipped = [UInt8](repeating: 0, count: bytes.count)
        for y in 0..<H { flipped.replaceSubrange(y * W * 4..<(y + 1) * W * 4, with: bytes[(H - 1 - y) * W * 4..<(H - y) * W * 4]) }
        bytes = flipped
        // composite over a stand-in wallpaper colour, BGRA → RGBA
        for i in stride(from: 0, to: bytes.count, by: 4) {
            let a = Double(bytes[i + 3]) / 255
            let b = Double(bytes[i]), g = Double(bytes[i + 1]), rr = Double(bytes[i + 2])
            bytes[i] = UInt8(min(255, rr + (1 - a) * 64))
            bytes[i + 1] = UInt8(min(255, g + (1 - a) * 77))
            bytes[i + 2] = UInt8(min(255, b + (1 - a) * 102))
            bytes[i + 3] = 255
        }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: W * 4, bitsPerPixel: 32),
              let data = rep.bitmapData else { return }
        bytes.withUnsafeBytes { data.update(from: $0.bindMemory(to: UInt8.self).baseAddress!, count: bytes.count) }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
