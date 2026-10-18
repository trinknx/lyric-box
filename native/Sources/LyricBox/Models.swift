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
    case auto, calm, mid, energetic, constellation, rap, glitch

    var title: String {
        switch self {
        case .auto: return "Tự động theo bài"
        case .calm: return "Êm dịu"
        case .mid: return "Vừa"
        case .energetic: return "Sôi động"
        case .constellation: return "Chòm sao (nối chữ như sao)"
        case .rap: return "Rap — từng chữ phóng to"
        case .glitch: return "Glitch — nhiễu, giật (rock / điện tử)"
        }
    }
}

enum BeatSync: String, CaseIterable {
    case off, soft, strong

    var title: String {
        switch self {
        case .off: return "Tắt"
        case .soft: return "Nhẹ — chữ và nền đập theo nhịp"
        case .strong: return "Mạnh — thêm chữ nảy theo nhịp"
        }
    }
}

enum FontSet: String, CaseIterable {
    case noto, system

    var title: String {
        switch self {
        case .noto: return "Noto Serif / Sans (giống COTODAMA)"
        case .system: return "Hệ thống (New York / SF)"
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
    var fontSet: FontSet {
        get { FontSet(rawValue: d.string(forKey: "fontSet") ?? "") ?? .noto }
        set { set(newValue.rawValue, "fontSet") }
    }
    var beatSync: BeatSync {
        get { BeatSync(rawValue: d.string(forKey: "beatSync") ?? "") ?? .strong }
        set { set(newValue.rawValue, "beatSync") }
    }
    /// Brief flashes on strong beats in energetic songs. Off by default (photosensitivity).
    var strobe: Bool {
        get { d.bool(forKey: "strobe") }
        set { set(newValue, "strobe") }
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
