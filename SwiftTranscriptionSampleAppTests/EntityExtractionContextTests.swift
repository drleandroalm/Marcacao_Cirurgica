import XCTest
import SwiftUI
@testable import SwiftTranscriptionSampleApp

final class EntityExtractionContextTests: XCTestCase {
    func test_ContextBuilderMatchesFixture() async throws {
        let data = try loadFixture(named: "entity_extraction_context_cases", withExtension: "json")
        let cases = try JSONDecoder().decode([ExtractionFixture].self, from: data)
        let form = await MainActor.run { SurgicalRequestForm() }
        let snapshots = await MainActor.run {
            form.fields.map { FieldSnapshot(id: $0.id, value: $0.value, fieldType: $0.fieldType) }
        }

        for fixture in cases {
            let context = await ExtractionSessionContext.build(originalText: fixture.transcript, fieldSnapshots: snapshots)
            XCTAssertEqual(context.deterministicFieldIds, Set(fixture.deterministicFieldIds), "Deterministic mismatch for \(fixture.name)")
            XCTAssertEqual(context.outstandingFieldIds, Set(fixture.outstandingFieldIds), "Outstanding mismatch for \(fixture.name)")
            XCTAssertFalse(context.tokens.isEmpty, "Tokens should not be empty for \(fixture.name)")
        }
    }

    func test_HighlightingCacheHighlightsSnippet() async {
        let highlight = HighlightedSpan(
            fieldId: "procedureName",
            snippet: "João",
            context: "Paciente João da Silva será avaliado",
            start: 9,
            end: 13,
            confidence: 0.82
        )
        let fragments = await HighlightingContextCache.shared.fragments(for: highlight)
        var snippetHasBackground = false
        let snippetAttributed = fragments.attributed
        for run in snippetAttributed.runs {
            guard run.backgroundColor != nil else { continue }
            let substring = snippetAttributed[run.range]
            let text = String(substring.characters)
            if text.lowercased().contains(highlight.snippet.lowercased()) {
                snippetHasBackground = true
                break
            }
        }
        XCTAssertTrue(snippetHasBackground, "Expected highlighted background for snippet")
    }

    func test_HighlightedTranscriptViewRendersWithoutCrash() {
        let highlight = HighlightedSpan(
            fieldId: "procedureName",
            snippet: "colecistectomia",
            context: "Procedimento colecistectomia será realizado amanhã",
            start: 12,
            end: 27,
            confidence: 0.74
        )
        let controller = UIHostingController(rootView: HighlightedTranscriptView(highlight: highlight))
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.view)
    }

    // MARK: - Helpers

    private func loadFixture(named name: String, withExtension ext: String) throws -> Data {
        let bundle = Bundle(for: type(of: self))
        guard let url = bundle.url(forResource: name, withExtension: ext) else {
            throw NSError(domain: "FixtureMissing", code: 0, userInfo: ["name": name])
        }
        return try Data(contentsOf: url)
    }

    private struct ExtractionFixture: Decodable {
        let name: String
        let transcript: String
        let deterministicFieldIds: [String]
        let outstandingFieldIds: [String]
    }
}
