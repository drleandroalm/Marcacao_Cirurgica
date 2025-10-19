import Foundation

struct FieldSnapshot: Sendable {
    let id: String
    let value: String
    let fieldType: FieldType
}

struct ExtractionSessionContext: Sendable {
    let originalText: String
    let preprocessedText: String
    let structuredStage: StructuredStageResult
    let residualText: String
    let missingFieldIds: Set<String>
    let deterministicFieldIds: Set<String>
    let tokens: [String]
    let fieldSnapshots: [FieldSnapshot]

    static func build(originalText: String, fieldSnapshots: [FieldSnapshot]) async -> ExtractionSessionContext {
        let trimmed = originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let preprocessed = EntityExtractor.expandAbbreviations(in: trimmed)
        async let tokensTask: [String] = tokenize(preprocessed)
        let structured = EntityExtractor.performStructuredStage(originalText: trimmed, preprocessedText: preprocessed)
        let tokens = await tokensTask

        let deterministicIds = Set(structured.entities.map { $0.fieldId })
        let missing = Set(fieldSnapshots.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map { $0.id })
        let residual = structured.residualText.trimmingCharacters(in: .whitespacesAndNewlines)
        let residualText = residual.isEmpty ? preprocessed : residual

        return ExtractionSessionContext(
            originalText: trimmed,
            preprocessedText: preprocessed,
            structuredStage: structured,
            residualText: residualText,
            missingFieldIds: missing,
            deterministicFieldIds: deterministicIds,
            tokens: tokens,
            fieldSnapshots: fieldSnapshots
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    var outstandingFieldIds: Set<String> {
        missingFieldIds.subtracting(deterministicFieldIds)
    }
}
