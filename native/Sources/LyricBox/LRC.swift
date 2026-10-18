import Foundation

/// LRC parsing (standard `[mm:ss.xx]` and enhanced `<mm:ss.xx>` word timings) and word timing estimation.
enum LRC {
    private static let lineTag = try! NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2}(?:[.:]\d{1,3})?)\]"#)
    private static let wordTag = try! NSRegularExpression(pattern: #"<(\d{1,3}):(\d{1,2}(?:\.\d{1,3})?)>"#)
    private static let metaTag = try! NSRegularExpression(pattern: #"^\s*\[(ti|ar|al|offset)\s*:(.*)\]\s*$"#, options: [.caseInsensitive])

    private static func seconds(_ m: String, _ s: String) -> Double {
        (Double(m) ?? 0) * 60 + (Double(s.replacingOccurrences(of: ":", with: ".")) ?? 0)
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (1..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }

    /// Lines for a song. Plain text without timestamps is spread evenly over the duration.
    static func lines(from text: String, duration: Double) -> [Line] {
        var raw: [(time: Double, body: String)] = []
        var off = 0.0
        for rawLine in text.precomposedStringWithCanonicalMapping.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let full = NSRange(location: 0, length: ns.length)
            if let m = metaTag.firstMatch(in: rawLine, range: full) {
                let g = groups(m, in: rawLine)
                if g[0].lowercased() == "offset" { off = (Double(g[1].trimmingCharacters(in: .whitespaces)) ?? 0) / 1000 }
                continue
            }
            let tags = lineTag.matches(in: rawLine, range: full)
            if tags.isEmpty { continue }
            let body = lineTag.stringByReplacingMatches(in: rawLine, range: full, withTemplate: "").trimmingCharacters(in: .whitespaces)
            for t in tags {
                let g = groups(t, in: rawLine)
                raw.append((max(0, seconds(g[0], g[1]) - off), body))
            }
        }
        raw.sort { $0.time < $1.time }

        if raw.isEmpty {
            let plain = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !plain.isEmpty else { return [] }
            let dur = duration > 0 ? duration : Double(plain.count) * 4
            // no timestamps: spread over the sung part (skip ~8% intro and outro)
            let start = min(15, dur * 0.08), step = (dur * 0.92 - start) / Double(plain.count)
            raw = plain.enumerated().map { (start + Double($0.offset) * step, $0.element) }
        }
        return raw.enumerated().map { i, r in
            build(time: r.time, body: r.body, next: i + 1 < raw.count ? raw[i + 1].time : nil)
        }
    }

    static func splitWords(_ text: String) -> [String] {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return [] }
        if t.rangeOfCharacter(from: .whitespaces) != nil {
            return t.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        }
        // no spaces (Japanese, Chinese…): let Foundation find the words
        var out: [String] = []
        t.enumerateSubstrings(in: t.startIndex..., options: .byWords) { w, _, _, _ in
            if let w { out.append(w) }
        }
        return out.isEmpty ? [t] : out
    }

    static func build(time: Double, body: String, next: Double?) -> Line {
        var words: [(text: String, time: Double?)] = []
        var text = ""
        let ns = body as NSString
        let tags = wordTag.matches(in: body, range: NSRange(location: 0, length: ns.length))
        if tags.isEmpty {
            text = body
            words = splitWords(body).map { ($0, nil) }
        } else {
            var cursor = 0
            var t: Double? = nil
            func addChunk(_ chunk: String) {
                guard !chunk.isEmpty else { return }
                let ws = splitWords(chunk)
                let glue = !words.isEmpty && !ws.isEmpty && !(chunk.first?.isWhitespace ?? false) && !(text.last?.isWhitespace ?? true)
                for (k, w) in ws.enumerated() {
                    if k == 0 && glue { words[words.count - 1].text += w } else { words.append((w, k == 0 ? t : nil)) }
                }
                text += chunk
            }
            for m in tags {
                addChunk(ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor)))
                let g = groups(m, in: body)
                t = seconds(g[0], g[1])
                cursor = m.range.location + m.range.length
            }
            addChunk(ns.substring(from: cursor))
        }

        let nextTime = next ?? time + 8
        let n = words.count
        var times = words.map { $0.time }
        if n > 0 {
            let singDur = max(0.3, min((nextTime - time) * 0.8, Double(n) * 0.5 + 0.3))
            if times.allSatisfy({ $0 == nil }) {
                // spread over the sung part, longer words take longer
                let weights = words.map { Double($0.text.count + 2) }
                let total = weights.reduce(0, +)
                var acc = 0.0
                for k in 0..<n { times[k] = time + singDur * acc / total; acc += weights[k] }
            } else {
                if times[0] == nil { times[0] = time }
                var last = 0
                for k in 1..<n where times[k] != nil {
                    let t0 = times[last]!, t1 = times[k]!
                    for j in (last + 1)..<max(last + 1, k) { times[j] = t0 + (t1 - t0) * Double(j - last) / Double(k - last) }
                    last = k
                }
                if last + 1 < n { for j in (last + 1)..<n { times[j] = times[last]! + 0.25 * Double(j - last) } }
            }
        }
        let finalWords = zip(words, times).map { Word(text: $0.0.text, time: $0.1 ?? time) }
        let lastWord = finalWords.last?.time ?? time
        let end = min(next ?? .infinity, lastWord + 6)
        return Line(time: time, end: end, text: text.trimmingCharacters(in: .whitespaces), words: finalWords)
    }
}
