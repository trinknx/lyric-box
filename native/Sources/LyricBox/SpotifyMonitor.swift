import AppKit
import QuartzCore

/// Follows the Spotify desktop app. Spotify broadcasts a distributed notification on
/// play / pause / track change; between those we re-read the position with an
/// in-process AppleScript every 1.5 s to correct drift (no login, no Web API).
final class SpotifyMonitor {
    enum Status { case ok, notInstalled, notRunning, idle, denied }

    private(set) var track: Track?
    private(set) var playing = false
    private(set) var status: Status = .notRunning
    private var anchorPos = 0.0
    private var anchorTime = CACurrentMediaTime()

    var onTrack: ((Track?) -> Void)?
    var onState: (() -> Void)?

    static let bundleID = "com.spotify.client"
    private var timer: Timer?

    // "is running" first so polling never launches Spotify
    private let script = NSAppleScript(source: """
    if application "Spotify" is running then
      tell application "Spotify"
        set pState to player state as string
        if pState is not "stopped" then
          set trk to current track
          return pState & tab & (id of trk) & tab & (name of trk) & tab & (artist of trk) & tab & (album of trk) & tab & ((duration of trk) / 1000) & tab & (player position)
        end if
      end tell
    end if
    return "off"
    """)!

    /// Playback position in seconds, extrapolated between polls.
    var position: Double {
        let p = playing ? anchorPos + (CACurrentMediaTime() - anchorTime) : anchorPos
        return min(p, track?.duration ?? p)
    }

    func start() {
        script.compileAndReturnError(nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(changed), name: .init("com.spotify.client.PlaybackStateChanged"), object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(changed), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(changed), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        poll()
        schedule()
    }

    private func schedule() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: playing ? 1.5 : 4, repeats: false) { [weak self] _ in
            self?.poll()
            self?.schedule()
        }
    }

    @objc private func changed() {
        // give Spotify a moment to update what AppleScript reports
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.poll()
            self?.schedule()
        }
    }

    private var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == Self.bundleID }
    }

    private func poll() {
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) != nil else {
            return update(status: .notInstalled, info: nil)
        }
        guard isRunning else { return update(status: .notRunning, info: nil) }

        var err: NSDictionary?
        let result = script.executeAndReturnError(&err)
        if let err {
            let code = err[NSAppleScript.errorNumber] as? Int ?? 0
            return update(status: code == -1743 ? .denied : .idle, info: nil)
        }
        let out = result.stringValue ?? "off"
        let f = out.components(separatedBy: "\t")
        guard out != "off", f.count >= 7 else { return update(status: .idle, info: nil) }
        let num = { (s: String) in Double(s.replacingOccurrences(of: ",", with: ".")) ?? 0 }
        let t = Track(id: f[1], name: f[2], artist: f[3], album: f[4], duration: num(f[5]))
        update(status: .ok, info: (t, f[0] == "playing", num(f[6])))
    }

    private func update(status: Status, info: (track: Track, playing: Bool, position: Double)?) {
        self.status = status
        let newTrack = info?.track.id != track?.id
        if let info {
            // ignore small drift (latency) so letters don't jump
            if newTrack || info.playing != playing || abs(position - info.position) > 0.3 {
                anchorPos = info.position
                anchorTime = CACurrentMediaTime()
            }
            playing = info.playing
            track = info.track
        } else {
            anchorPos = position
            anchorTime = CACurrentMediaTime()
            playing = false
            track = nil
        }
        if newTrack { onTrack?(track) }
        onState?()
    }
}
