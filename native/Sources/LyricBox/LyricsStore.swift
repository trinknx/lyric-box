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

    /// Synced lyrics for a track, or nil (only lyrics with timestamps are used: they follow Spotify).
    /// `complete` is false when LRCLIB failed along the way (busy / offline), so a synced
    /// version may still exist and it's worth asking again later.
    /// Debug: LYRICBOX_LRCLIB_FAIL=N makes the next N LRCLIB requests fail as if the server were busy.
    nonisolated(unsafe) static var simulatedFailures = Int(ProcessInfo.processInfo.environment["LYRICBOX_LRCLIB_FAIL"] ?? "") ?? 0

    func lyrics(for t: Track, refresh: Bool = false, completion: @escaping (_ lrc: String?, _ complete: Bool) -> Void) {
        if !refresh, Self.simulatedFailures == 0, let lrc = cache[key(t)] { return completion(lrc, true) }
        Task {
            let (lrc, complete) = await Self.fetch(t)
            await MainActor.run {
                if let lrc, Self.isSynced(lrc) { self.set(t, lrc) }
                completion(lrc, complete || (lrc.map(Self.isSynced) ?? false))
            }
        }
    }

    /// One LRCLIB request, retried when the server is busy (503 / 429) or the network fails.
    /// Returns (json, ok); ok is false when every attempt failed.
    private static func get(_ path: String, _ params: [String: String]) async -> (Any?, Bool) {
        var c = URLComponents(string: "https://lrclib.net/api/" + path)!
        c.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: c.url!, timeoutInterval: 10)
        req.setValue("LyricBox/0.4 (macOS desktop lyric wallpaper)", forHTTPHeaderField: "User-Agent")
        if simulatedFailures > 0 {
            simulatedFailures -= 1
            return (nil, false)
        }
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000) }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let code = (resp as? HTTPURLResponse)?.statusCode else { continue }
            if code == 404 { return (nil, true) }          // simply not there
            guard code == 200, let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let d = json as? [String: Any], d["statusCode"] != nil { continue }   // error body with 200
            return (json, true)
        }
        return (nil, false)
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

    private static func fetch(_ t: Track) async -> (String?, Bool) {
        var complete = true
        let artist = t.artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .components(separatedBy: " feat").first?.trimmingCharacters(in: .whitespaces) ?? t.artist
        var params = ["track_name": t.name, "artist_name": artist, "duration": String(Int(t.duration.rounded()))]
        if !t.album.isEmpty { params["album_name"] = t.album }
        let (exactJSON, exactOK) = await get("get", params)
        complete = complete && exactOK
        if let exact = exactJSON as? [String: Any], let lrc = exact["syncedLyrics"] as? String, !lrc.isEmpty {
            return (lrc, true)
        }
        // "Song - Remastered 2011", "Song (feat. X)"… often miss: search loosely
        let clean = t.name.replacingOccurrences(
            of: #"\s*[-(\[].*(remaster|feat|ft\.|version|edit|live|mix).*$"#, with: "",
            options: [.regularExpression, .caseInsensitive]).trimmingCharacters(in: .whitespaces)
        for q in [["track_name": clean, "artist_name": artist], ["q": "\(artist) \(clean)"]] {
            let (json, ok) = await get("search", q)
            complete = complete && ok
            guard let items = json as? [[String: Any]] else { continue }
            let matches = items.filter { same($0, clean, t.duration) }
                .sorted { abs(($0["duration"] as? Double ?? 0) - t.duration) < abs(($1["duration"] as? Double ?? 0) - t.duration) }
            if let lrc = matches.lazy.compactMap({ $0["syncedLyrics"] as? String }).first(where: { !$0.isEmpty }) {
                return (lrc, true)
            }
        }
        return (nil, complete)
    }
}
