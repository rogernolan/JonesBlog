import Foundation

nonisolated enum PostTextLinkifier {
    nonisolated struct CacheMetrics: Equatable, Sendable {
        let detectorRuns: Int
        let cacheHits: Int
    }

    private static let cache = LinkificationCache()

    static var cacheMetrics: CacheMetrics {
        cache.metrics
    }

    static func resetCacheForTesting() {
        cache.reset()
    }

    static func attributedString(_ text: String) -> AttributedString {
        if let cached = cache.attributedString(for: text) {
            return cached
        }

        var attributed = AttributedString(text)
        for match in linkMatches(in: text) {
            guard let url = match.url,
                  let textRange = Range(match.range, in: text),
                  let lowerBound = AttributedString.Index(textRange.lowerBound, within: attributed),
                  let upperBound = AttributedString.Index(textRange.upperBound, within: attributed) else {
                continue
            }
            attributed[lowerBound..<upperBound].link = url
        }
        cache.store(attributed, for: text)
        return attributed
    }

    static func html(_ text: String) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0

        for match in linkMatches(in: text) {
            guard let url = match.url else { continue }
            let prefixRange = NSRange(location: cursor, length: match.range.location - cursor)
            result += escape(source.substring(with: prefixRange))

            let label = source.substring(with: match.range)
            result += "<a href=\"\(escape(url.absoluteString))\">\(escape(label))</a>"
            cursor = NSMaxRange(match.range)
        }

        let suffixRange = NSRange(location: cursor, length: source.length - cursor)
        result += escape(source.substring(with: suffixRange))
        return result
    }

    private static func linkMatches(in text: String) -> [NSTextCheckingResult] {
        cache.linkMatches(in: text)
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}

private final class LinkificationCache: @unchecked Sendable {
    private let lock = NSLock()
    private let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )
    private var attributedStrings: [String: AttributedString] = [:]
    private var detectorRuns = 0
    private var cacheHits = 0

    var metrics: PostTextLinkifier.CacheMetrics {
        lock.withLock {
            .init(detectorRuns: detectorRuns, cacheHits: cacheHits)
        }
    }

    func attributedString(for text: String) -> AttributedString? {
        lock.withLock {
            guard let attributed = attributedStrings[text] else { return nil }
            cacheHits += 1
            return attributed
        }
    }

    func store(_ attributedString: AttributedString, for text: String) {
        lock.withLock {
            if attributedStrings.count >= 256 {
                attributedStrings.removeAll(keepingCapacity: true)
            }
            attributedStrings[text] = attributedString
        }
    }

    func linkMatches(in text: String) -> [NSTextCheckingResult] {
        lock.lock()
        defer { lock.unlock() }
        guard let detector else { return [] }
        detectorRuns += 1
        return detector.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ).filter { match in
            guard let scheme = match.url?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
    }

    func reset() {
        lock.withLock {
            attributedStrings.removeAll(keepingCapacity: false)
            detectorRuns = 0
            cacheHits = 0
        }
    }
}
