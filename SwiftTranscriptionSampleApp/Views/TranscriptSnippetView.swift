import SwiftUI

struct TranscriptSnippetView: View {
    let snippet: String
    var title: String = "Trecho reconhecido"
    var accentColor: Color = .purple
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(snippet)
                .font(.footnote)
                .foregroundColor(.primary)
                .padding(8)
                .background(accentColor.opacity(0.08))
                .cornerRadius(6)
        }
    }
}
