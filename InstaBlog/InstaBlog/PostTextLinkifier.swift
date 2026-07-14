import Foundation

nonisolated enum PostTextLinkifier {
    static func attributedString(_ text: String) -> AttributedString {
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
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue
        ) else {
            return []
        }

        return detector.matches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: (text as NSString).length)
        ).filter { match in
            guard let scheme = match.url?.scheme?.lowercased() else { return false }
            return scheme == "http" || scheme == "https"
        }
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
