import AppKit
import IOKit.pwr_mgt

/* Screen-saver mode: after a while without input (and while Spotify plays), the lyrics
   cover every screen in front of all windows. Any mouse movement or key press brings
   the desktop back; the key goes to the saver, not to the app underneath. While it is
   showing and music plays, the display is kept awake so the system screen saver or
   display sleep don't kick in on top of it. A real .saver bundle can't be used: macOS
   runs those in a sandboxed host that can't talk to Spotify. */

/// Full-screen window above everything (screen-saver level).
final class SaverWindow: NSWindow {
    let scene: LyricScene
    var onInput: (() -> Void)?

    init(screen: NSScreen) {
        scene = LyricScene(size: screen.frame.size, backing: screen.backingScaleFactor)
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layerUsesCoreImageFilters = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.addSublayer(scene.root)
        contentView = view
        setFrame(screen.frame, display: true)
        alphaValue = 0
    }

    override var canBecomeKey: Bool { true }   // so key presses land here, not in the app below
    override func keyDown(with event: NSEvent) { onInput?() }
    override func mouseDown(with event: NSEvent) { onInput?() }
    override func rightMouseDown(with event: NSEvent) { onInput?() }
    override func scrollWheel(with event: NSEvent) { onInput?() }
}

final class SaverController {
    private(set) var windows: [SaverWindow] = []
    private(set) var showing = false
    private var shownAt = 0.0
    private var previousApp: NSRunningApplication?
    private var awake: IOPMAssertionID = 0

    /// Prepares a fresh scene the same way as the wallpaper scenes (theme, track, lyrics…).
    var configure: ((LyricScene) -> Void)?

    var scenes: [LyricScene] { windows.map { $0.scene } }

    /// Seconds since the last keyboard / mouse / trackpad input (no permission needed).
    static var idleSeconds: Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func show() {
        guard !showing else { return }
        showing = true
        shownAt = CACurrentMediaTime()
        previousApp = NSWorkspace.shared.frontmostApplication
        windows = NSScreen.screens.map { s in
            let w = SaverWindow(screen: s)
            w.onInput = { [weak self] in self?.hide() }
            configure?(w.scene)
            return w
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in windows {
            w.orderFrontRegardless()
            w.animator().alphaValue = 1
        }
        windows.first?.makeKey()
        NSCursor.setHiddenUntilMouseMoves(true)
    }

    func hide() {
        guard showing else { return }
        showing = false
        let ws = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ws.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { ws.forEach { $0.orderOut(nil) } })
        previousApp?.activate()
        previousApp = nil
        keepAwake(false)
    }

    /// Called every tick. `idleMinutes` 0 = off.
    func update(idleMinutes: Int, onlyWhilePlaying: Bool, playing: Bool) {
        let idle = Self.idleSeconds
        if showing {
            // any input (after a short grace so the click that opened a preview doesn't close it)
            if idle < 0.4 && CACurrentMediaTime() - shownAt > 1.2 { hide(); return }
            if onlyWhilePlaying && !playing && CACurrentMediaTime() - shownAt > 1.2 { hide(); return }
            keepAwake(playing)
            return
        }
        guard idleMinutes > 0, !onlyWhilePlaying || playing else { return }
        if idle >= Double(idleMinutes * 60) { show() }
    }

    /// Keeps the display (and the system screen saver) from taking over while lyrics play.
    private func keepAwake(_ on: Bool) {
        if on && awake == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Lyric Box screen saver" as CFString, &awake)
        } else if !on && awake != 0 {
            IOPMAssertionRelease(awake)
            awake = 0
        }
    }
}
