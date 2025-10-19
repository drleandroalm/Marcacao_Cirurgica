import SwiftUI

struct HighlightFragments: Sendable {
    let attributed: AttributedString
}

actor HighlightingContextCache {
    static let shared = HighlightingContextCache()

    private var cache: [String: HighlightFragments] = [:]

    func fragments(for highlight: HighlightedSpan) -> HighlightFragments {
        let key = cacheKey(for: highlight)
        if let cached = cache[key] { return cached }
        let fragments = HighlightFragments(attributed: buildAttributedString(for: highlight))
        cache[key] = fragments
        return fragments
    }

    func clear() {
        cache.removeAll()
    }

    private func cacheKey(for highlight: HighlightedSpan) -> String {
        "\(highlight.fieldId)|\(highlight.start)|\(highlight.end)|\(highlight.context.hashValue)"
    }

    private func buildAttributedString(for highlight: HighlightedSpan) -> AttributedString {
        var attributed = AttributedString(highlight.context)
        let lowerContext = highlight.context.lowercased()
        let lowerSnippet = highlight.snippet.lowercased()

        if let range = lowerContext.range(of: lowerSnippet) {
            let prefixCount = lowerContext.distance(from: lowerContext.startIndex, to: range.lowerBound)
            let snippetCount = lowerContext.distance(from: range.lowerBound, to: range.upperBound)
            let startIndex = highlight.context.index(highlight.context.startIndex, offsetBy: prefixCount)
            let endIndex = highlight.context.index(startIndex, offsetBy: snippetCount)
            let originalRange = startIndex..<endIndex
            if let spanRange = Range(originalRange, in: attributed) {
                attributed[spanRange].foregroundColor = .white
                attributed[spanRange].backgroundColor = Color.gray.opacity(0.35)
            }
        }

        return attributed
    }
}
