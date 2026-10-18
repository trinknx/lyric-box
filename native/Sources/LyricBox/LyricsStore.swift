import Foundation

/// Synced lyrics from LRCLIB (https://lrclib.net), cached on disk
/// (same file as the Electron version, so the cache carries over).
final class LyricsStore {
    private var cache: [String: String] = [:]
    private let file: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lyric Box", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("lyrics-cache.json")
        if let data = try? Data(contentsOf: file),
           let c = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = c
        }
    }

    private func key(_ t: Track) -> String { "\(t.artist)|\(t.name)".lowercased() }

    func set(_ t: Track, _ lrc: String) {
        cache[key(t)] = lrc
        if cache.count > 300 { cache.keys.prefix(cache.count - 300).forEach { cache.removeValue(forKey: $0) } }
        let snapshot = cache
        let url = file
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    /// True when the text has `[mm:ss]` timestamps.
    static func isSynced(_ s: String) -> Bool {
        s.range(of: #"\[\d{1,3}:\d{2}"#, options: .regularExpression) != nil
    }

    /// Synced lyrics if any source has them, otherwise plain text (only synced lyrics are cached,
    /// so a song gets picked up again once LRCLIB gains timestamps for it).
    func lyrics(for t: Track, refresh: Bool = false, completion: @escaping (String?) -> Void) {
        if !refresh, let lrc = cache[key(t)] { return completion(lrc) }
        Task {
            let lrc = await Self.fetch(t)
            await MainActor.run {
                if let lrc, Self.isSynced(lrc) { self.set(t, lrc) }
                completion(lrc)
            }
        }
    }

    private static func get(_ path: String, _ params: [String: String]) async -> Any? {
        var c = URLComponents(string: "https://lrclib.net/api/" + path)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("LyricBox/0.2 (macOS desktop lyric wallpaper)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Letters and digits only, no accents ("Lệ Quyên" → "lequyen").
    private static func fold(_ s: String) -> String {
        let f = s.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
        return String(f.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// A search hit is the same song: names match (ignoring accents / extras) and the length is close.
    private static func same(_ item: [String: Any], _ name: String, _ duration: Double) -> Bool {
        let a = fold(item["trackName"] as? String ?? ""), b = fold(name)
        guard !a.isEmpty, !b.isEmpty, a.contains(b) || b.contains(a) else { return false }
        return abs((item["duration"] as? Double ?? 0) - duration) < 6
    }

    private static func fetch(_ t: Track) async -> String? {
        let artist = t.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .components(separatedBy: " feat").first?.trimmingCharacters(in: .whitespaces) ?? t.artist
        var params = ["track_name": t.name, "artist_name": artist, "duration": String(Int(t.duration.rounded()))]
        if !t.album.isEmpty { params["album_name"] = t.album }
        var plain: String?
        if let exact = await get("get", params) as? [String: Any] {
            if let lrc = exact["syncedLyrics"] as? String, !lrc.isEmpty { return lrc }
            plain = exact["plainLyrics"] as? String
        }
        // "Song - Remastered 2011", "Song (feat. X)"… often miss: search loosely
        let clean = t.name.replacingOccurrences(
            of: #"\s*[-(\[].*(remaster|feat|ft\.|version|edit|live|mix).*$"#, with: "",
            options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        for q in [["track_name": clean, "artist_name": artist], ["q": "\(artist) \(clean)"]] {
            guard let items = await get("search", q) as? [[String: Any]] else { continue }
            let matches = items.filter { same($0, clean, t.duration) }
                .sorted { abs(($0["duration"] as? Double ?? 0) - t.duration) < abs(($1["duration"] as? Double ?? 0) - t.duration) }
            if let lrc = matches.lazy.compactMap({ $0["syncedLyrics"] as? String }).first(where: { !$0.isEmpty }) {
                return lrc
            }
            // remember plain text from the same song in case nothing synced turns up
            if plain == nil {
                plain = matches.lazy.compactMap { $0["plainLyrics"] as? String }.first { !$0.isEmpty }
            }
        }
        return plain.flatMap { $0.isEmpty ? nil : $0 }
    }
}
