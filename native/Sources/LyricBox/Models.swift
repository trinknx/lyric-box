import Foundation

struct Track: Equatable {
    let id: String
    let name: String
    let artist: String
    let album: String
    let duration: Double // seconds
}

struct Word {
    var text: String
    var time: Double
}

struct Line {
    var time: Double
    var end: Double
    var text: String
    var words: [Word]
}

/// Deterministic random numbers so a line always gets the same layout (same LCG as the web version).
struct SeededRandom {
    private var s: UInt32
    init(_ seed: UInt32) { s = seed == 0 ? 1 : seed }
    mutating func next() -> Double {
        s = s &* 1664525 &+ 1013904223
        return Double(s) / 4294967296
    }
}

/// FNV-1a over unicode scalars.
func hashString(_ str: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for u in str.unicodeScalars {
        h ^= u.value
        h = h &* 16777619
    }
    return h
}

enum Theme: String, CaseIterable {
    case night, clear, glassLight = "glass-light", glassDark = "glass-dark"

    var title: String {
        switch self {
        case .night: return "Tối"
        case .clear: return "Sáng (acrylic trong)"
        case .glassLight: return "Trong suốt — chữ trắng"
        case .glassDark: return "Trong suốt — chữ đen"
        }
    }
}

enum MoodSetting: String, CaseIterable {
    case auto, calm, mid, energetic

    var title: String {
        switch self {
        case .auto: return "Tự động theo bài"
        case .calm: return "Êm dịu"
        case .mid: return "Vừa"
        case .energetic: return "Sôi động"
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let d = UserDefaults.standard
    var onChange: ((String) -> Void)?

    private func set(_ v: Any, _ k: String) {
        d.set(v, forKey: k)
        onChange?(k)
    }

    var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { set(newValue, "enabled") }
    }
    var theme: Theme {
        get { Theme(rawValue: d.string(forKey: "theme") ?? "") ?? .night }
        set { set(newValue.rawValue, "theme") }
    }
    var mood: MoodSetting {
        get { MoodSetting(rawValue: d.string(forKey: "mood") ?? "") ?? .auto }
        set { set(newValue.rawValue, "mood") }
    }
    /// "primary", "all" or a display id
    var display: String {
        get { d.string(forKey: "display") ?? "primary" }
        set { set(newValue, "display") }
    }
    var caption: Bool {
        get { d.object(forKey: "caption") as? Bool ?? true }
        set { set(newValue, "caption") }
    }
    var offset: Double {
        get { d.double(forKey: "offset") }
        set { set((newValue * 100).rounded() / 100, "offset") }
    }
}
