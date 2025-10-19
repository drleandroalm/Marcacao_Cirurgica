import SwiftUI

struct HighlightedTranscriptView: View {
    let highlight: HighlightedSpan
    let accentColor: Color

    @State private var attributed: AttributedString = AttributedString("")
    @State private var isLoaded = false

    init(highlight: HighlightedSpan, accentColor: Color = .accentColor) {
        self.highlight = highlight
        self.accentColor = accentColor
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                if isLoaded {
                    Text(attributed)
                        .font(.callout)
                        .foregroundStyle(Color.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(nil)
                        .minimumScaleFactor(0.9)
                } else {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .scaleEffect(0.6)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Label("\(Int(highlight.confidence * 100))% confiança", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(accentColor)
                Text("Trecho \(highlight.start)–\(highlight.end)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(labelText)
        .accessibilityHint("Trecho destacado na transcrição com confiança associada")
        .task(id: cacheKey) {
            let fragments = await HighlightingContextCache.shared.fragments(for: highlight)
            await MainActor.run {
                var attributedString = fragments.attributed
                applyAccentColor(&attributedString)
                attributed = attributedString
                isLoaded = true
            }
        }
    }

    private var cacheKey: String {
        "\(highlight.fieldId)|\(highlight.start)|\(highlight.end)"
    }

    private var labelText: Text {
        Text("Campo \(highlight.fieldId): \(Int(highlight.confidence * 100))% de confiança. Trecho: \(highlight.snippet)")
    }

    private func applyAccentColor(_ attributed: inout AttributedString) {
        for run in attributed.runs {
            guard run.backgroundColor != nil else { continue }
            let range = run.range
            attributed[range].backgroundColor = accentColor.opacity(0.85)
            attributed[range].foregroundColor = .white
        }
    }
}
