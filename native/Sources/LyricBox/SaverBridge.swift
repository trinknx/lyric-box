import Foundation

/// How the Lyric Box app feeds the macOS screen saver (Lyric Box.saver).
/// The saver runs in Apple's sandboxed screen-saver host and can't read Spotify, so the app
/// sends it what's playing over distributed notifications. Payloads travel as JSON in the
/// notification's object string (sandboxed processes can't use userInfo).
enum Bridge {
    static let hello = Notification.Name("io.bamboosoft.lyricbox.saver.hello")   // saver → app, every few seconds
    static let state = Notification.Name("io.bamboosoft.lyricbox.state")         // app → saver, every second
    static let lyrics = Notification.Name("io.bamboosoft.lyricbox.lyrics")       // app → saver, per song
    static let beat = Notification.Name("io.bamboosoft.lyricbox.beat")           // app → saver, per beat

    struct State: Codable {
        var id = "", name = "", artist = "", album = ""
        var duration = 0.0, position = 0.0, ts = 0.0     // ts: wall-clock time of `position`
        var playing = false
        var theme = "night", mood = "auto", fontSet = "noto", beatSync = "strong"
        var strobe = false, caption = true
        var offset = 0.0
    }

    struct Lyrics: Codable {
        var id: String
        var lrc: String?
    }

    static func post(_ name: Notification.Name, _ object: String? = nil) {
        DistributedNotificationCenter.default().postNotificationName(name, object: object, userInfo: nil, deliverImmediately: true)
    }

    static func encode<T: Encodable>(_ v: T) -> String? {
        (try? JSONEncoder().encode(v)).flatMap { String(data: $0, encoding: .utf8) }
    }

    static func decode<T: Decodable>(_ object: Any?, as: T.Type) -> T? {
        (object as? String)?.data(using: .utf8).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }
}
