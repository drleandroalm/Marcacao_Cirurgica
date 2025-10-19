import Foundation
import FoundationModels
import os

// Helper function for timeout
private struct _Box<T>: @unchecked Sendable { let value: T }

struct ExtractionSpan: Sendable {
    let start: Int
   let end: Int
   let snippet: String
}

struct HighlightedSpan: Sendable {
    let fieldId: String
    let snippet: String
    let context: String
    let start: Int
    let end: Int
    let confidence: Double
}

struct ConfidenceSignal: Sendable {
    let source: String
    let score: Double
}

struct FieldConfidenceSnapshot: Sendable {
    let fieldId: String
    let aggregatedConfidence: Double
    let signals: [ConfidenceSignal]
    let highlight: HighlightedSpan?
}

struct StructuredStageResult: Sendable {
    let entities: [ExtractedEntity]
    let residualText: String
}

func withTimeout<T>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: _Box<T>.self) { group in
        group.addTask {
            let value = try await operation()
            return _Box(value: value)
        }
        
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw EntityExtractionError.timeout
        }
        
        let result = try await group.next()!
        group.cancelAll()
        return result.value
    }
}

struct ExtractedEntity: Sendable {
    let fieldId: String
    let value: String
    let confidence: Double
    let alternatives: [String]
    let originalText: String
    let span: ExtractionSpan?
    let signals: [ConfidenceSignal]

    init(fieldId: String,
         value: String,
         confidence: Double,
         alternatives: [String],
         originalText: String,
         span: ExtractionSpan? = nil,
         signals: [ConfidenceSignal] = []) {
        self.fieldId = fieldId
        self.value = value
        self.confidence = confidence
        self.alternatives = alternatives
        self.originalText = originalText
        self.span = span
        self.signals = signals
    }
}

struct ExtractionResult: Sendable {
    var entities: [ExtractedEntity]
    let unprocessedText: String
    let confidence: Double
    let diagnostics: [FieldConfidenceSnapshot]
    let highlights: [String: HighlightedSpan]

    init(entities: [ExtractedEntity],
         unprocessedText: String,
         confidence: Double,
         diagnostics: [FieldConfidenceSnapshot] = [],
         highlights: [String: HighlightedSpan] = [:]) {
        self.entities = entities
        self.unprocessedText = unprocessedText
        self.confidence = confidence
        self.diagnostics = diagnostics
        self.highlights = highlights
    }
}

@Observable
@MainActor
/// Extracts structured entities from transcripts using on-device language models and deterministic fallbacks.
class EntityExtractor {
    private var configuration: ExtractionConfiguration
    private let model: SystemLanguageModel
    private var session: LanguageModelSession?
    private var isSessionReady = false
    nonisolated private static let metricsLog = OSLog(subsystem: "SwiftTranscriptionSampleApp", category: "EntityExtractor")
    nonisolated private static let preferredDeterministicFieldIds: Set<String> = ["surgeryDate", "surgeryTime", "patientPhone", "procedureDuration"]
    
    nonisolated private static func redactedSummary(for text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        return "<redacted len=\(trimmed.count) words=\(wordCount)>"
    }
    
    nonisolated private static func redactedValue(_ value: String) -> String {
        "<len=\(value.count)>"
    }
    
    static let shared = EntityExtractor()
    
    init(configuration: ExtractionConfiguration = ExtractionConfiguration(), model: SystemLanguageModel = .default) {
        self.configuration = configuration
        self.model = model
        Task {
            await setupSession()
        }
    }
    
    private func setupSession() async {
        guard model.isAvailable else { 
            print("⚠️ Foundation Models not available")
            return 
        }
        
        session = LanguageModelSession(
            model: model,
            instructions: """
            You are a medical form extraction specialist.
            Extract entities from Portuguese medical transcriptions.
            Always respond with valid JSON only, no explanations.
            Match entities to known values when possible.
            """
        )
        isSessionReady = true
        print("✅ EntityExtractor session ready")
    }
    
    var isAvailable: Bool {
        return model.isAvailable
    }
    
    func updateConfiguration(_ configuration: ExtractionConfiguration) {
        self.configuration = configuration
    }

    // MARK: - Abbreviation expansion utility (shared with fallback)
    nonisolated static func expandAbbreviations(in text: String) -> String {
        var processed = text
        for (abbr, expansion) in MedicalKnowledgeBase.abbreviationExpansions {
            let pattern = "\\b\(abbr)\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: processed.utf16.count)
                processed = regex.stringByReplacingMatches(
                    in: processed,
                    options: [],
                    range: range,
                    withTemplate: expansion
                )
            }
        }
        return processed
    }

    func extractEntities(from transcription: String, for form: SurgicalRequestForm) async throws -> ExtractionResult {
        let snapshots = form.fields.map { field in
            FieldSnapshot(id: field.id, value: field.value, fieldType: field.fieldType)
        }
        let context = await ExtractionSessionContext.build(originalText: transcription, fieldSnapshots: snapshots)
        return try await extractEntities(using: context, form: form)
    }

    func extractEntities(using context: ExtractionSessionContext, form: SurgicalRequestForm) async throws -> ExtractionResult {
        let signpostID = OSSignpostID(log: Self.metricsLog)
        os_signpost(.begin, log: Self.metricsLog, name: "extractEntities()", signpostID: signpostID)
        defer { os_signpost(.end, log: Self.metricsLog, name: "extractEntities()", signpostID: signpostID) }

        let transcription = context.originalText
        print("🔍 EntityExtractor: Starting extraction \(Self.redactedSummary(for: transcription))")

        guard isAvailable else {
            print("❌ EntityExtractor: Model unavailable")
            throw EntityExtractionError.modelUnavailable
        }

        let trimmedText = transcription.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count
        guard trimmedText.count > 20 || wordCount >= 5 else {
            print("⚠️ EntityExtractor: Text too short (\(trimmedText.count) chars, \(wordCount) words) - skipping extraction")
            return ExtractionResult(entities: [], unprocessedText: transcription, confidence: 0)
        }

        var aggregatedEntities = context.structuredStage.entities
        var residualTextForPrompt = context.residualText
        if !aggregatedEntities.isEmpty {
            print("🧱 Stage 1 deterministic locked \(aggregatedEntities.count) fields")
            for entity in aggregatedEntities {
                print("  - \(entity.fieldId): \(Self.redactedValue(entity.value)) [deterministic]")
            }
        }

        var outstanding = context.outstandingFieldIds
        if !outstanding.isEmpty {
            let knowledgeEntities = performKnowledgeBaseStage(context: context, outstanding: outstanding)
            for entity in knowledgeEntities where !aggregatedEntities.contains(where: { $0.fieldId == entity.fieldId }) {
                aggregatedEntities.append(entity)
                print("📚 KB stage proposed \(entity.fieldId) = \(Self.redactedValue(entity.value))")
            }
            outstanding.subtract(knowledgeEntities.map { $0.fieldId })
        }

        if residualTextForPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            residualTextForPrompt = context.preprocessedText
        }

        if outstanding.isEmpty {
            let baseResult = ExtractionResult(
                entities: aggregatedEntities,
                unprocessedText: residualTextForPrompt,
                confidence: Self.averageConfidence(for: aggregatedEntities)
            )
            var result = await Task.detached(priority: .userInitiated) {
                Self.enhanceWithKnowledgeBase(baseResult)
            }.value
            result = finalizeResult(result, originalTranscript: transcription)
            result = await refineLowConfidenceEntities(result, originalTranscript: transcription)
            logConfidenceDiagnostics(result)
            return result
        }

        if !isSessionReady || session == nil {
            print("🔄 Setting up EntityExtractor session...")
            await setupSession()
        }

        guard let session = session else {
            throw EntityExtractionError.sessionUnavailable
        }

        let promptBuildID = OSSignpostID(log: Self.metricsLog)
        os_signpost(.begin, log: Self.metricsLog, name: "buildExtractionPrompt", signpostID: promptBuildID)
        let prompt = buildExtractionPrompt(for: residualTextForPrompt, fields: form.fields, targetFieldIds: outstanding)
        os_signpost(.end, log: Self.metricsLog, name: "buildExtractionPrompt", signpostID: promptBuildID)

        do {
            print("🤖 EntityExtractor: Sending prompt to FoundationModels...")
            print("📝 Prompt length: \(prompt.count) characters")

            let llmID = OSSignpostID(log: Self.metricsLog)
            os_signpost(.begin, log: Self.metricsLog, name: "LLMRespond", signpostID: llmID)
            let response = try await withTimeout(seconds: configuration.responseTimeout) {
                try await session.respond(to: prompt)
            }
            os_signpost(.end, log: Self.metricsLog, name: "LLMRespond", signpostID: llmID)

            print("✅ EntityExtractor: Got response from model (len=\(response.content.count) chars)")

            let parseID = OSSignpostID(log: Self.metricsLog)
            os_signpost(.begin, log: Self.metricsLog, name: "parseExtractionResponse", signpostID: parseID)
            let parsedResult = try parseExtractionResponse(response.content, originalText: transcription, allowedFieldIds: outstanding)
            os_signpost(.end, log: Self.metricsLog, name: "parseExtractionResponse", signpostID: parseID)
            print("📊 EntityExtractor: Parsed \(parsedResult.entities.count) entities")

            var combinedEntitiesById: [String: ExtractedEntity] = [:]
            for entity in aggregatedEntities {
                combinedEntitiesById[entity.fieldId] = entity
            }
            for entity in parsedResult.entities {
                if let existing = combinedEntitiesById[entity.fieldId] {
                    if Self.preferredDeterministicFieldIds.contains(entity.fieldId) {
                        continue
                    }
                    if entity.confidence > existing.confidence {
                        combinedEntitiesById[entity.fieldId] = entity
                    }
                } else {
                    combinedEntitiesById[entity.fieldId] = entity
                }
            }

            let combinedEntities = Array(combinedEntitiesById.values)
            let combinedResult = ExtractionResult(
                entities: combinedEntities,
                unprocessedText: parsedResult.unprocessedText,
                confidence: Self.averageConfidence(for: combinedEntities)
            )

            var result = await Task.detached(priority: .userInitiated) {
                Self.enhanceWithKnowledgeBase(combinedResult)
            }.value

            let requiredIds = configuration.requiredFieldIds
            let presentIds = Set(result.entities.map { $0.fieldId })
            if !requiredIds.isSubset(of: presentIds) {
                let supplementID = OSSignpostID(log: Self.metricsLog)
                os_signpost(.begin, log: Self.metricsLog, name: "supplementWithFallback", signpostID: supplementID)
                print("🧩 Supplementing entities with fallback extraction for missing fields…")
                let fallback = try await performFallbackExtraction(for: transcription)
                var merged: [String: ExtractedEntity] = [:]
                for e in result.entities { merged[e.fieldId] = e }
                for e in fallback.entities where merged[e.fieldId] == nil {
                    merged[e.fieldId] = e
                }
                let mergedEntities = Array(merged.values)
                var supplemented = ExtractionResult(
                    entities: mergedEntities,
                    unprocessedText: result.unprocessedText.isEmpty ? fallback.unprocessedText : result.unprocessedText,
                    confidence: max(result.confidence, fallback.confidence)
                )
                supplemented = Self.enhanceWithKnowledgeBase(supplemented)
                result = supplemented
                os_signpost(.end, log: Self.metricsLog, name: "supplementWithFallback", signpostID: supplementID)
            }

            result = finalizeResult(result, originalTranscript: transcription)
            result = await refineLowConfidenceEntities(result, originalTranscript: transcription)

            print("🏁 EntityExtractor: Final result - \(result.entities.count) entities, confidence: \(result.confidence)")
            for entity in result.entities {
                if let field = form.fields.first(where: { $0.id == entity.fieldId }) {
                    let confidencePercent = Int(entity.confidence * 100)
                    print("  - \(field.label): \(Self.redactedValue(entity.value)) (confidence: \(confidencePercent)%)")
                    if let span = entity.span {
                        print("    span: \(span.start)-\(span.end) snippet=\(Self.redactedValue(span.snippet))")
                    }
                    if !entity.signals.isEmpty {
                        let signalSummary = entity.signals.map { "\($0.source)=\(Int($0.score * 100))%" }.joined(separator: ", ")
                        print("    signals: \(signalSummary)")
                    }
                }
            }
            logConfidenceDiagnostics(result)
            return result
        } catch {
            print("❌ EntityExtractor: Extraction failed: \(error)")
            print("🔄 Attempting fallback extraction...")
            return try await performFallbackExtraction(for: transcription)
        }
    }
    
    private func performFallbackExtraction(for text: String) async throws -> ExtractionResult {
        // Run on the main actor to respect actor isolation for helper methods
        let id = OSSignpostID(log: Self.metricsLog)
        os_signpost(.begin, log: Self.metricsLog, name: "performFallbackExtraction", signpostID: id)
        let r = try Self.fallbackExtraction(from: text)
        os_signpost(.end, log: Self.metricsLog, name: "performFallbackExtraction", signpostID: id)
        return r
    }

    nonisolated static func performStructuredStage(originalText: String, preprocessedText: String) -> StructuredStageResult {
        var rangesToRemove: [Range<String.Index>] = []
        var entities: [ExtractedEntity] = []
        var lockedFields: Set<String> = []

        func overlapsExisting(_ candidate: Range<String.Index>) -> Bool {
            for existing in rangesToRemove {
                if candidate.overlaps(existing) {
                    return true
                }
            }
            return false
        }

        @discardableResult
        func appendEntity(fieldId: String, value: String, range: Range<String.Index>, confidence: Double) -> Bool {
            guard !lockedFields.contains(fieldId) else { return false }
            guard !overlapsExisting(range) else { return false }
            let span = makeSpan(range: range, inProcessedText: preprocessedText, originalText: originalText)
            let entity = ExtractedEntity(
                fieldId: fieldId,
                value: value,
                confidence: max(0.0, min(1.0, confidence)),
                alternatives: [],
                originalText: originalText,
                span: span,
                signals: [ConfidenceSignal(source: "deterministic", score: confidence)]
            )
            entities.append(entity)
            lockedFields.insert(fieldId)
            rangesToRemove.append(range)
            return true
        }

        // Date patterns (numeric first, then textual)
        let numericDatePattern = #"(\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4})"#
        if let match = preprocessedText.range(of: numericDatePattern, options: [.regularExpression]) {
            let raw = String(preprocessedText[match])
            let formatted = formatDate(raw)
            if !formatted.isEmpty {
                _ = appendEntity(fieldId: "surgeryDate", value: formatted, range: match, confidence: 0.96)
            }
        }

        if !lockedFields.contains("surgeryDate") {
            let textualPattern = #"(\d{1,2})\s+de\s+(janeiro|fevereiro|março|marco|abril|maio|junho|julho|agosto|setembro|outubro|novembro|dezembro)(?:\s+de\s+(\d{4}))?"#
            if let match = preprocessedText.range(of: textualPattern, options: [.regularExpression, .caseInsensitive]) {
                let raw = String(preprocessedText[match])
                let formatted = formatDate(raw)
                if !formatted.isEmpty {
                    _ = appendEntity(fieldId: "surgeryDate", value: formatted, range: match, confidence: 0.93)
                }
            }
        }

        // Time patterns
        let timePatterns = [
            #"(?:às\s*)?(\d{1,2}):(\d{2})"#,
            #"(?:às\s*)?(\d{1,2})h(\d{2})"#
        ]
        if !lockedFields.contains("surgeryTime") {
            for pattern in timePatterns {
                if let match = preprocessedText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    let raw = String(preprocessedText[match])
                    let formatted = formatTime(raw)
                    if !formatted.isEmpty && appendEntity(fieldId: "surgeryTime", value: formatted, range: match, confidence: 0.95) {
                        break
                    }
                }
            }
        }

        // Phone number
        let phonePattern = #"(\d{2}\D*\d{4,5}\D*\d{4})"#
        if let match = preprocessedText.range(of: phonePattern, options: [.regularExpression]) {
            let raw = String(preprocessedText[match])
            let digits = raw.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
            if (10...11).contains(digits.count) {
                _ = appendEntity(fieldId: "patientPhone", value: digits, range: match, confidence: 0.94)
            }
        }

        // Duration patterns
        let durationPatterns = [
            #"(\d{1,2})[:hH](\d{2})"#,
            #"(\d{1,2})\s*horas?(?:\s*e\s*(\d{1,2})\s*minutos?)?"#,
            #"(\d{1,2})\s*minutos?"#
        ]
        if !lockedFields.contains("procedureDuration") {
            for pattern in durationPatterns {
                if let match = preprocessedText.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                    let raw = String(preprocessedText[match])
                    let formatted = formatDuration(raw)
                    if !formatted.isEmpty && appendEntity(fieldId: "procedureDuration", value: formatted, range: match, confidence: 0.92) {
                        break
                    }
                }
            }
        }

        let residual = removeRanges(rangesToRemove, from: preprocessedText)
        return StructuredStageResult(entities: entities, residualText: residual)
    }

    nonisolated static func deterministicStagePreview(for text: String) -> StructuredStageResult {
        let preprocessed = expandAbbreviations(in: text)
        return performStructuredStage(originalText: text, preprocessedText: preprocessed)
    }

    nonisolated static func aggregateConfidence(signals: [ConfidenceSignal], fallback: Double) -> Double {
        guard !signals.isEmpty else { return fallback }
        let maxSignal = signals.map { $0.score }.max() ?? fallback
        let averageSignal = signals.reduce(0.0) { $0 + $1.score } / Double(signals.count)
        let deterministic = signals.first(where: { $0.source == "deterministic" })?.score ?? 0
        let knowledge = signals.first(where: { $0.source == "knowledgeBase" })?.score ?? 0
        let anchor = max(deterministic, knowledge, fallback)
        var combined = (0.5 * maxSignal) + (0.3 * averageSignal) + (0.2 * anchor)
        combined = max(combined, fallback)
        combined = max(combined, maxSignal)
        return min(1.0, combined)
    }

    nonisolated private static func finalizeEntities(_ entities: [ExtractedEntity]) -> [ExtractedEntity] {
        entities.map { entity in
            var filteredSignals = entity.signals.filter { $0.source != "aggregate" }
            let aggregated = aggregateConfidence(signals: filteredSignals, fallback: entity.confidence)
            filteredSignals.append(ConfidenceSignal(source: "aggregate", score: aggregated))
            return ExtractedEntity(
                fieldId: entity.fieldId,
                value: entity.value,
                confidence: aggregated,
                alternatives: entity.alternatives,
                originalText: entity.originalText,
                span: entity.span,
                signals: filteredSignals
            )
        }
    }

    nonisolated private static func averageConfidence(for entities: [ExtractedEntity]) -> Double {
        guard !entities.isEmpty else { return 0 }
        let sum = entities.reduce(0.0) { $0 + $1.confidence }
        return sum / Double(entities.count)
    }

    nonisolated private static func buildDiagnostics(for entities: [ExtractedEntity], originalText: String) -> ([FieldConfidenceSnapshot], [String: HighlightedSpan]) {
        var highlights: [String: HighlightedSpan] = [:]
        let snapshots = entities.map { entity -> FieldConfidenceSnapshot in
            let highlight = makeHighlight(for: entity, originalText: originalText)
            if let highlight { highlights[entity.fieldId] = highlight }
            return FieldConfidenceSnapshot(
                fieldId: entity.fieldId,
                aggregatedConfidence: entity.confidence,
                signals: entity.signals,
                highlight: highlight
            )
        }
        return (snapshots, highlights)
    }

    nonisolated private static func makeHighlight(for entity: ExtractedEntity, originalText: String) -> HighlightedSpan? {
        guard let span = entity.span else { return nil }
        let length = originalText.count
        guard length > 0 else { return nil }

        let boundedStart = max(0, min(span.start, length))
        let boundedEnd = max(boundedStart, min(span.end, length))

        let startIndex = originalText.index(originalText.startIndex, offsetBy: boundedStart)
        let endIndex = originalText.index(originalText.startIndex, offsetBy: boundedEnd)
        let snippet = String(originalText[startIndex..<endIndex])

        let contextRadius = 60
        let contextStartOffset = max(0, boundedStart - contextRadius)
        let contextEndOffset = min(length, boundedEnd + contextRadius)
        let contextStartIndex = originalText.index(originalText.startIndex, offsetBy: contextStartOffset)
        let contextEndIndex = originalText.index(originalText.startIndex, offsetBy: contextEndOffset)
        let context = String(originalText[contextStartIndex..<contextEndIndex])

        return HighlightedSpan(
            fieldId: entity.fieldId,
            snippet: snippet.isEmpty ? span.snippet : snippet,
            context: context,
            start: boundedStart,
            end: boundedEnd,
            confidence: entity.confidence
        )
    }

    private func finalizeResult(_ result: ExtractionResult, originalTranscript: String) -> ExtractionResult {
        let finalized = Self.finalizeEntities(result.entities)
        let diagnostics = Self.buildDiagnostics(for: finalized, originalText: originalTranscript)
        return ExtractionResult(
            entities: finalized,
            unprocessedText: result.unprocessedText,
            confidence: Self.averageConfidence(for: finalized),
            diagnostics: diagnostics.0,
            highlights: diagnostics.1
        )
    }

    private func performKnowledgeBaseStage(context: ExtractionSessionContext, outstanding: Set<String>) -> [ExtractedEntity] {
        guard !outstanding.isEmpty else { return [] }
        var results: [ExtractedEntity] = []
        let lowercased = context.preprocessedText.lowercased()

        if outstanding.contains("surgeonName"),
           let match = Self.detectSurgeonViaKnowledgeBase(in: lowercased) {
            let signals = [ConfidenceSignal(source: "knowledgeBase", score: match.confidence)]
            results.append(
                ExtractedEntity(
                    fieldId: "surgeonName",
                    value: match.value,
                    confidence: match.confidence,
                    alternatives: match.alternatives,
                    originalText: context.originalText,
                    span: nil,
                    signals: signals
                )
            )
        }

        if outstanding.contains("procedureName"),
           let match = Self.detectProcedureViaKnowledgeBase(in: lowercased) {
            let signals = [ConfidenceSignal(source: "knowledgeBase", score: match.confidence)]
            results.append(
                ExtractedEntity(
                    fieldId: "procedureName",
                    value: match.value,
                    confidence: match.confidence,
                    alternatives: match.alternatives,
                    originalText: context.originalText,
                    span: nil,
                    signals: signals
                )
            )
        }

        return results
    }

    private func merge(entity: ExtractedEntity, with refinement: ExtractedEntity) -> ExtractedEntity {
        var mergedSignals = entity.signals.filter { $0.source != "aggregate" }
        mergedSignals.append(contentsOf: refinement.signals)
        let mergedAlternatives = Array(Set(entity.alternatives + refinement.alternatives + [entity.value]))
        return ExtractedEntity(
            fieldId: entity.fieldId,
            value: refinement.value,
            confidence: refinement.confidence,
            alternatives: mergedAlternatives,
            originalText: refinement.originalText,
            span: entity.span ?? refinement.span,
            signals: mergedSignals
        )
    }

    private func refineLowConfidenceEntities(_ result: ExtractionResult, originalTranscript: String) async -> ExtractionResult {
        let threshold = 0.75
        let requiredIds = configuration.requiredFieldIds
        var entities = result.entities

        let lowConfidenceIndices = entities.enumerated().compactMap { index, entity -> Int? in
            guard requiredIds.contains(entity.fieldId), entity.confidence < threshold else { return nil }
            return index
        }

        guard !lowConfidenceIndices.isEmpty else { return result }

        let candidates = lowConfidenceIndices.map { entities[$0] }
        var refinedIndices: Set<Int> = []

        if let batchRefinements = await batchRefineEntities(candidates, originalTranscript: originalTranscript) {
            for index in lowConfidenceIndices {
                let entity = entities[index]
                if let refinement = batchRefinements[entity.fieldId] {
                    entities[index] = merge(entity: entity, with: refinement)
                    refinedIndices.insert(index)
                }
            }
        }

        for index in lowConfidenceIndices where !refinedIndices.contains(index) {
            let entity = entities[index]
            do {
                if let refined = try await refineEntity(fieldId: entity.fieldId, originalValue: entity.value, context: originalTranscript) {
                    entities[index] = merge(entity: entity, with: refined)
                    refinedIndices.insert(index)
                }
            } catch {
                continue
            }
        }

        guard !refinedIndices.isEmpty else { return result }
        let refinedResult = ExtractionResult(
            entities: entities,
            unprocessedText: result.unprocessedText,
            confidence: result.confidence,
            diagnostics: result.diagnostics
        )
        return finalizeResult(refinedResult, originalTranscript: originalTranscript)
    }

    private func logConfidenceDiagnostics(_ result: ExtractionResult) {
        guard !result.diagnostics.isEmpty else { return }
        print("📈 Confidence diagnostics:")
        for snapshot in result.diagnostics {
            let percent = Int(snapshot.aggregatedConfidence * 100)
            let signalSummary = snapshot.signals.isEmpty
                ? "-"
                : snapshot.signals.map { "\($0.source)=\(Int($0.score * 100))%" }.joined(separator: ", ")
            print("  • \(snapshot.fieldId): \(percent)% [\(signalSummary)]")
        }
    }

    nonisolated private static func makeSpan(range: Range<String.Index>, inProcessedText processed: String, originalText: String) -> ExtractionSpan {
        let snippet = String(processed[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        if let originalRange = originalText.range(of: snippet, options: .caseInsensitive) {
            let start = originalText.distance(from: originalText.startIndex, to: originalRange.lowerBound)
            let end = originalText.distance(from: originalText.startIndex, to: originalRange.upperBound)
            return ExtractionSpan(start: start, end: end, snippet: snippet)
        }
        let fallbackStart = processed.distance(from: processed.startIndex, to: range.lowerBound)
        let fallbackEnd = processed.distance(from: processed.startIndex, to: range.upperBound)
        return ExtractionSpan(start: fallbackStart, end: fallbackEnd, snippet: snippet)
    }

    nonisolated private static func removeRanges(_ ranges: [Range<String.Index>], from text: String) -> String {
        guard !ranges.isEmpty else { return text }
        var mutable = text
        for range in ranges.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            mutable.removeSubrange(range)
        }
        return mutable
    }

    nonisolated private static func enhanceWithKnowledgeBase(_ result: ExtractionResult) -> ExtractionResult {
        print("🔍 EntityExtractor: Enhancing entities with knowledge base...")
        var enhancedEntities = result.entities

        for (index, entity) in enhancedEntities.enumerated() {
            switch entity.fieldId {
            case "surgeonName":
                let matchResult = IntelligentMatcher.matchSurgeon(entity.value)
                if matchResult.isKnownEntity && matchResult.confidence > entity.confidence {
                    enhancedEntities[index] = ExtractedEntity(
                        fieldId: entity.fieldId,
                        value: matchResult.value,
                        confidence: matchResult.confidence,
                        alternatives: matchResult.alternatives,
                        originalText: entity.originalText,
                        span: entity.span,
                        signals: entity.signals + [ConfidenceSignal(source: "knowledgeBase", score: matchResult.confidence)]
                    )
                }
                
            case "procedureName":
                let matchResult = IntelligentMatcher.matchProcedure(entity.value)
                if matchResult.isKnownEntity && matchResult.confidence > entity.confidence {
                    enhancedEntities[index] = ExtractedEntity(
                        fieldId: entity.fieldId,
                        value: matchResult.value,
                        confidence: matchResult.confidence,
                        alternatives: matchResult.alternatives,
                        originalText: entity.originalText,
                        span: entity.span,
                        signals: entity.signals + [ConfidenceSignal(source: "knowledgeBase", score: matchResult.confidence)]
                    )
                }
                
            default:
                break
            }
        }

        // Recalculate overall confidence
        let finalized = finalizeEntities(enhancedEntities)
        return ExtractionResult(
            entities: finalized,
            unprocessedText: result.unprocessedText,
            confidence: averageConfidence(for: finalized),
            diagnostics: result.diagnostics,
            highlights: result.highlights
        )
    }
    
    private func buildExtractionPrompt(for text: String, fields: [TemplateField], targetFieldIds: Set<String>) -> String {
        let filteredFields: [TemplateField]
        let currentTargetIds: Set<String> = targetFieldIds.isEmpty ? Set(fields.map { $0.id }) : targetFieldIds
        filteredFields = fields.filter { currentTargetIds.contains($0.id) }
        let fieldsDescription = filteredFields.map { field in
            let typeDescription = getFieldTypeDescription(field.fieldType)
            return "- \(field.id): \(field.label) (\(typeDescription))"
        }.joined(separator: "\n")
        
        // Include known entities for better recognition
        let knownSurgeons = MedicalKnowledgeBase.surgeons.map { $0.canonical }.joined(separator: ", ")
        let commonProcedures = MedicalKnowledgeBase.procedures.prefix(10).map { $0.canonical }.joined(separator: ", ")
        
        return """
        Você é um assistente especializado em extrair informações médicas de transcrições em português brasileiro.

        CAMPOS DO FORMULÁRIO:
        \(fieldsDescription)

        CONHECIMENTO PRÉVIO DOS CIRURGIÕES COMUNS:
        \(knownSurgeons)

        PROCEDIMENTOS MÉDICOS CONHECIDOS (exemplos):
        \(commonProcedures)

        ABREVIAÇÕES MÉDICAS:
        - OSC = Orquiectomia Subcapsular Bilateral
        - VLP = Videolaparoscópica
        - IPP = Implante de Prótese Peniana
        - UI = Uretrotomia Interna
        - RTU = Ressecção Transuretral

        REGRAS DE EXTRAÇÃO:
        1. Priorize correspondências com entidades conhecidas
        2. Use correspondência fonética para nomes similares
        3. Expanda abreviações automaticamente
        4. Extraia informações mesmo quando ditas fora de ordem
        5. Todos os nomes próprios devem começar com letra maiúscula
        6. Datas no formato DD/MM/AAAA
        7. Horários no formato HH:MM
        8. Telefones apenas números (10-11 dígitos)
        9. Idades apenas números
        10. Se não encontrar uma informação, retorne "VAZIO"
        11. Sempre inclua o objeto `sourceSpan` com pelo menos o campo `snippet` contendo o trecho exato do texto utilizado na decisão. Informe também `start` e `end` como índices de caractere referentes ao texto enviado abaixo sempre que possível.
        12. Indique confiança numérica (0-100) baseada na certeza da resposta.
        13. Não repita campos que já foram confirmados como "VAZIO" em outra parte da resposta.
        14. Responda apenas para os IDs de campo listados na seção CAMPOS DO FORMULÁRIO.

        TRANSCRIÇÃO RESIDUAL FORNECIDA:
        "\(text)"

        RESPONDA EXATAMENTE NESTE FORMATO JSON:
        {
            "entities": [
                {
                    "fieldId": "patientName",
                    "value": "João Silva",
                    "confidence": 95,
                    "alternatives": ["João da Silva", "João Santos"],
                    "sourceSpan": {
                        "snippet": "paciente João Silva",
                        "start": 12,
                        "end": 30
                    }
                }
            ],
            "unprocessed": "texto não processado",
            "overallConfidence": 87
        }

        Não adicione texto explicativo, apenas o JSON válido.
        """
    }
    
    private func getFieldTypeDescription(_ fieldType: FieldType) -> String {
        switch fieldType {
        case .text:
            return "Nome próprio ou texto livre"
        case .age:
            return "Idade em anos (ex: 45)"
        case .number:
            return "Número (ex: idade)"
        case .date:
            return "Data no formato DD/MM/AAAA"
        case .time:
            return "Horário no formato HH:MM"
        case .duration:
            return "Duração em HH:MM (ex: 01:30)"
        case .phone:
            return "Telefone (10-11 dígitos)"
        }
    }
    
    private func parseExtractionResponse(_ response: String, originalText: String, allowedFieldIds: Set<String>) throws -> ExtractionResult {
        print("🔍 Parsing response of \(response.count) characters")
        
        // Try to robustly extract JSON from the response (in case there's extra text)
        if let firstBrace = response.firstIndex(of: "{"),
           let lastBrace = response.lastIndex(of: "}") {
            let jsonString = String(response[firstBrace...lastBrace])
            if let jsonData = jsonString.data(using: .utf8) {
                do {
                    return try parseJSONResponse(jsonData, originalText: originalText, allowedFieldIds: allowedFieldIds)
                } catch {
                    print("⚠️ JSON slicing parse failed, falling back to direct parse/error: \(error)")
                }
            }
        }
        
        // Fallback: try direct parse of the whole string
        guard let jsonData = response.data(using: .utf8) else {
            print("⚠️ Could not convert response to data, trying fallback extraction")
            return try Self.fallbackExtraction(from: originalText)
        }
        
        do {
            return try parseJSONResponse(jsonData, originalText: originalText, allowedFieldIds: allowedFieldIds)
        } catch {
            print("⚠️ Direct JSON parse failed: \(error). Falling back.")
            return try Self.fallbackExtraction(from: originalText)
        }
    }

    private func parseJSONResponse(_ jsonData: Data, originalText: String, allowedFieldIds: Set<String>) throws -> ExtractionResult {
        do {
            let raw = try JSONSerialization.jsonObject(with: jsonData)
            guard let json = raw as? [String: Any] else {
                throw EntityExtractionError.invalidResponse
            }
            print("📦 Successfully parsed JSON")
            
            guard let entitiesArray = json["entities"] as? [[String: Any]] else {
                throw EntityExtractionError.invalidResponse
            }
            
            // Accept overallConfidence as Double or Int
            var overallConfidence: Double = 0
            if let ocDouble = json["overallConfidence"] as? Double {
                overallConfidence = ocDouble
            } else if let ocInt = json["overallConfidence"] as? Int {
                overallConfidence = Double(ocInt)
            } else {
                // If not provided, estimate later from entities
                overallConfidence = 0
            }
            
            let entities = entitiesArray.compactMap { entityDict -> ExtractedEntity? in
                guard let fieldId = entityDict["fieldId"] as? String,
                      let value = entityDict["value"] as? String else {
                    return nil
                }

                if !allowedFieldIds.isEmpty && !allowedFieldIds.contains(fieldId) {
                    print("⚠️ Ignoring unexpected field id from model: \(fieldId)")
                    return nil
                }
                
                // Accept confidence as Double or Int
                var confidencePct: Double = 0
                if let cDouble = entityDict["confidence"] as? Double {
                    confidencePct = cDouble
                } else if let cInt = entityDict["confidence"] as? Int {
                    confidencePct = Double(cInt)
                } else {
                    // Default if missing
                    confidencePct = 70
                }
                
                // Alternatives may be missing or empty
                let alternatives = entityDict["alternatives"] as? [String] ?? []
                var span: ExtractionSpan? = nil
                if let spanDict = entityDict["sourceSpan"] as? [String: Any] {
                    if let start = spanDict["start"] as? Int,
                       let end = spanDict["end"] as? Int {
                        let snippet = (spanDict["snippet"] as? String) ?? ""
                        span = ExtractionSpan(start: start, end: end, snippet: snippet)
                    }
                }
                
                // Skip empty values
                guard value != "VAZIO" && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                // Apply capitalization only to proper-name like fields
                let normalizedValue: String
                switch fieldId {
                case "patientName", "surgeonName", "procedureName":
                    normalizedValue = Self.capitalizeProperly(value)
                default:
                    normalizedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
                }

                return ExtractedEntity(
                    fieldId: fieldId,
                    value: normalizedValue,
                    confidence: max(0.0, min(1.0, confidencePct / 100.0)), // 0.0 ... 1.0
                    alternatives: alternatives.map { alt in
                        switch fieldId {
                        case "patientName", "surgeonName", "procedureName": return Self.capitalizeProperly(alt)
                        default: return alt
                        }
                    },
                    originalText: originalText,
                    span: span,
                    signals: [ConfidenceSignal(source: "model", score: max(0.0, min(1.0, confidencePct / 100.0)))]
                )
            }
            
            // Unprocessed text may come under different keys
            let unprocessed = (json["unprocessed"] as? String)
                ?? (json["unprocessedText"] as? String)
                ?? ""
            
            // If overallConfidence wasn't provided, estimate from entities
            let finalOverall = overallConfidence > 0
                ? max(0.0, min(1.0, overallConfidence / 100.0))
                : (entities.isEmpty ? 0 : entities.map { $0.confidence }.reduce(0, +) / Double(entities.count))
            
            return ExtractionResult(
                entities: entities,
                unprocessedText: unprocessed,
                confidence: finalOverall
            )
            
        } catch {
            // Fallback: try to extract using basic pattern matching
            return try Self.fallbackExtraction(from: originalText)
        }
    }
    
    nonisolated private static func capitalizeProperly(_ text: String) -> String {
        return text.split(separator: " ")
            .map { word in
                let lowercased = word.lowercased()
                
                // Don't capitalize articles, prepositions, and conjunctions in Portuguese
                let dontCapitalize = ["de", "da", "do", "das", "dos", "e", "em", "na", "no", "nas", "nos", "com", "para", "por", "a", "o", "as", "os"]
                
                if dontCapitalize.contains(lowercased) {
                    return String(lowercased)
                } else {
                    return String(word.prefix(1).uppercased() + word.dropFirst().lowercased())
                }
            }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    nonisolated static func fallbackExtraction(from text: String) throws -> ExtractionResult {
        print("🔍 Fallback extraction: Processing \(Self.redactedSummary(for: text))")
        let id = OSSignpostID(log: metricsLog)
        os_signpost(.begin, log: metricsLog, name: "fallbackExtraction", signpostID: id)
        
        var entities: [ExtractedEntity] = []
        // Expand known abbreviations first (e.g., RTU, RTUP, UTL, etc.)
        let expanded = expandAbbreviations(in: text)
        let lowercased = expanded.lowercased()
        let words = lowercased.split(separator: " ").map(String.init)
        print("📊 Starting pattern matching for all 8 fields...")
        
        // 1. Extract patient name - enhanced patterns
        let namePatterns = [
            ("paciente", 1, 3),  // "paciente João Silva"
            ("nome", 1, 3),      // "nome João Silva"
            ("senhor", 1, 3),    // "senhor João Silva"
            ("senhora", 1, 3),   // "senhora Maria Silva"
        ]
        
        for (keyword, startOffset, endOffset) in namePatterns {
            if let keyIndex = words.firstIndex(where: { $0.lowercased().contains(keyword) }),
               keyIndex + startOffset < words.count {
                let endIndex = min(keyIndex + endOffset, words.count - 1)
                let name = words[keyIndex + startOffset...endIndex]
                    .filter { !["de", "da", "do", "dos", "das"].contains($0.lowercased()) || $0.count > 2 }
                    .joined(separator: " ")
                
                if !name.isEmpty && name.count > 2 {
                    entities.append(ExtractedEntity(
                        fieldId: "patientName",
                        value: Self.capitalizeProperly(name),
                        confidence: 0.75,
                        alternatives: [],
                        originalText: text
                    ))
                    print("👤 Found patient name \(Self.redactedValue(name))")
                    break
                }
            }
        }
        
        // 2. Extract age - enhanced patterns
        let agePatterns = [
            #"(\d{1,3})\s*anos?"#,
            #"idade\s+(?:de\s+)?(\d{1,3})"#,
            #"(\d{1,3})\s*(?:anos?\s+)?(?:de\s+)?idade"#
        ]
        
        for pattern in agePatterns {
            if let ageMatch = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let ageStr = String(text[ageMatch])
                if let ageNumber = ageStr.components(separatedBy: CharacterSet.decimalDigits.inverted)
                    .compactMap({ Int($0) })
                    .first,
                   ageNumber > 0 && ageNumber < 150 {
                    entities.append(ExtractedEntity(
                        fieldId: "patientAge",
                        value: String(ageNumber),
                        confidence: 0.85,
                        alternatives: [],
                        originalText: text
                    ))
                    print("🎂 Found age \(Self.redactedValue(String(ageNumber)))")
                    break
                }
            }
        }
        
        // 3. Extract phone - enhanced patterns (allow any non-digit separators like ')' or '.')
        let phonePatterns = [
            #"(?:telefone|celular|contato)\s*(?:é\s*)?(?:o\s*)?(\d{2}\D*\d{4,5}\D*\d{4})"#,
            #"(\d{2}\D*\d{4,5}\D*\d{4})"#,
            #"(\d{10,11})"#
        ]
        
        for pattern in phonePatterns {
            if let phoneMatch = expanded.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let phoneStr = String(expanded[phoneMatch])
                let phone = phoneStr.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()
                if (8...11).contains(phone.count) {
                    let conf: Double = (phone.count >= 10) ? 0.8 : 0.65
                    entities.append(ExtractedEntity(
                        fieldId: "patientPhone",
                        value: phone,
                        confidence: conf,
                        alternatives: [],
                        originalText: text
                    ))
                    print("📞 Found phone \(Self.redactedValue(phone))")
                    break
                }
            }
        }
        
        // 4. Extract date - enhanced patterns
        let dateKeywords = [
            "amanhã": 1,
            "depois de amanhã": 2,
            "hoje": 0
        ]
        
        var dateFound = false
        for (keyword, daysToAdd) in dateKeywords {
            if lowercased.contains(keyword) {
                let targetDate = Calendar.current.date(byAdding: .day, value: daysToAdd, to: Date())!
                
                let formatter = DateFormatter()
                formatter.dateFormat = "dd/MM/yyyy"
                entities.append(ExtractedEntity(
                    fieldId: "surgeryDate",
                    value: formatter.string(from: targetDate),
                    confidence: 0.9,
                    alternatives: [],
                    originalText: text
                ))
                print("📅 Found date via keyword \(keyword)")
                dateFound = true
                break
            }
        }
        
        if !dateFound {
            // Weekday mapping (e.g., próxima segunda)
            if let weekdayDate = TranscriptionProcessor.computeWeekdayDate(from: lowercased) {
                let formatter = DateFormatter(); formatter.dateFormat = "dd/MM/yyyy"
                entities.append(ExtractedEntity(
                    fieldId: "surgeryDate",
                    value: formatter.string(from: weekdayDate),
                    confidence: 0.8,
                    alternatives: [],
                    originalText: text
                ))
                dateFound = true
            }
        }
        
        if !dateFound {
            let datePatterns = [
                #"(\d{1,2}[/\-]\d{1,2}[/\-]\d{2,4})"#,
                #"dia\s+(\d{1,2})\s+de\s+(\w+)"#,
                #"(\d{1,2})\s+de\s+(\w+)"#
            ]
            
            for pattern in datePatterns {
                if let dateMatch = text.range(of: pattern, options: .regularExpression) {
                    let date = String(text[dateMatch])
                    entities.append(ExtractedEntity(
                        fieldId: "surgeryDate",
                        value: formatDate(date),
                        confidence: 0.8,
                        alternatives: [],
                        originalText: text
                    ))
                    print("📅 Found date \(Self.redactedValue(date))")
                    break
                }
            }
        }
        
        // 5. Extract time - enhanced patterns
        let timePatterns = [
            #"(?:às\s*)?(\d{1,2}):(\d{2})"#,
            #"(?:às\s*)?(\d{1,2})[hH](\d{2})"#,
            #"(\d{1,2})\s*(?:e\s*)?(\d{2})?\s*horas?"#,
            #"(?:horário|hora)\s*(?:é\s*)?(?:às\s*)?(\d{1,2})[:hH]?(\d{2})?"#
        ]
        
        var foundTime = false
        for pattern in timePatterns {
            if let timeMatch = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let timeStr = String(text[timeMatch])
                let time = formatTime(timeStr)
                if !time.isEmpty {
                    entities.append(ExtractedEntity(
                        fieldId: "surgeryTime",
                        value: time,
                        confidence: 0.85,
                        alternatives: [],
                        originalText: text
                    ))
                    print("🕰 Found time \(Self.redactedValue(time))")
                    foundTime = true
                    break
                }
            }
        }
        
        // 6. Extract surgeon - enhanced patterns
        let surgeonPatterns = [
            ("doutor", 1, 3),
            ("doutora", 1, 3),
            ("dr", 1, 3),
            ("dra", 1, 3),
            ("médico", 1, 3),
            ("cirurgião", 1, 3),
            ("preceptor", 1, 3)
        ]

        for (keyword, startOffset, endOffset) in surgeonPatterns {
            if let keyIndex = words.firstIndex(where: { 
                $0 == keyword || $0 == "\(keyword)."
            }),
               keyIndex + startOffset < words.count {
                let endIndex = min(keyIndex + endOffset, words.count - 1)
                let surgeonName = words[keyIndex + startOffset...endIndex]
                    .filter { !["de", "da", "do", "dos", "das"].contains($0) || $0.count > 2 }
                    .joined(separator: " ")

                if !surgeonName.isEmpty && surgeonName.count > 2 {
                    entities.append(ExtractedEntity(
                        fieldId: "surgeonName",
                        value: Self.capitalizeProperly(surgeonName),
                        confidence: 0.75,
                        alternatives: [],
                        originalText: text
                    ))
                    print("👨‍⚕️ Found surgeon \(Self.redactedValue(surgeonName))")
                    break
                }
            }
        }
        
        // 7. Extract procedure - enhanced patterns
        let procedureKeywords = [
            "apendicectomia", "colecistectomia", "hernioplastia", "laparoscopia",
            "artroscopia", "endoscopia", "colonoscopia", "biópsia", "ressecção",
            "implante", "prótese", "cirurgia", "operação", "procedimento",
            "intervenção", "tratamento"
        ]

        for keyword in procedureKeywords {
            if lowercased.contains(keyword) {
                if let procIndex = words.firstIndex(where: { $0.contains(keyword) }) {
                    // Get more context around the procedure
                    let startIdx = max(0, procIndex - 2)
                    let endIdx = min(procIndex + 2, words.count - 1)
                    let procName = words[startIdx...endIdx]
                        .filter { !["de", "da", "do", "a", "o", "para"].contains($0) || $0.contains(keyword) }
                        .joined(separator: " ")
                    
                    entities.append(ExtractedEntity(
                        fieldId: "procedureName",
                        value: Self.capitalizeProperly(procName),
                        confidence: 0.7,
                        alternatives: [],
                        originalText: text
                    ))
                    print("🔧 Found procedure \(Self.redactedValue(procName))")
                    break
                }
            }
        }

        // KB-assisted detection when prefixes/keywords are not present
        func hasEntity(_ id: String) -> Bool { entities.contains { $0.fieldId == id } }

        if !hasEntity("surgeonName") {
            if let kbSurgeon = detectSurgeonViaKnowledgeBase(in: lowercased) {
                entities.append(ExtractedEntity(
                    fieldId: "surgeonName",
                    value: kbSurgeon.value,
                    confidence: kbSurgeon.confidence,
                    alternatives: kbSurgeon.alternatives,
                    originalText: text
                ))
                print("👨‍⚕️ KB matched surgeon \(Self.redactedValue(kbSurgeon.value))")
            }
        }

        if !hasEntity("procedureName") {
            if let kbProcedure = detectProcedureViaKnowledgeBase(in: lowercased) {
                entities.append(ExtractedEntity(
                    fieldId: "procedureName",
                    value: kbProcedure.value,
                    confidence: kbProcedure.confidence,
                    alternatives: kbProcedure.alternatives,
                    originalText: text
                ))
                print("🔧 KB matched procedure \(Self.redactedValue(kbProcedure.value))")
            }
        }
        
        // 8. Extract duration - new field handling
        let durationPatterns = [
            #"(\d+)\s*(?:a\s*)?(\d+)?\s*horas?"#,
            #"(\d+)\s*minutos?"#,
            #"duração\s*(?:de\s*)?(\d+)\s*(?:a\s*)?(\d+)?\s*horas?"#,
            #"tempo\s*(?:estimado\s*)?(?:de\s*)?(\d+)\s*horas?"#
        ]
        
        let hasDurationKeyword = lowercased.contains("duração") || lowercased.contains("duracao") || lowercased.contains("tempo") || lowercased.contains("estimad")
        for pattern in durationPatterns {
            if let durationMatch = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                let durationStr = String(text[durationMatch])
                // Disambiguate phrases like "uma hora da tarde" when time already detected
                let segmentLower = durationStr.lowercased()
                let looksLikeClockPhrase = segmentLower.contains("hora") && (lowercased.contains("da tarde") || lowercased.contains("da noite") || lowercased.contains("da manhã") || lowercased.contains("de manhã"))
                if foundTime && !hasDurationKeyword && looksLikeClockPhrase {
                    continue
                }
                // If time was found and there is no duration keyword, be conservative for hours-only matches
                if foundTime && !hasDurationKeyword && (segmentLower.contains("hora") && !segmentLower.contains("minuto")) {
                    continue
                }
                let duration = formatDuration(durationStr)
                if !duration.isEmpty {
                    entities.append(ExtractedEntity(
                        fieldId: "procedureDuration",
                        value: duration,
                        confidence: 0.75,
                        alternatives: [],
                        originalText: text
                    ))
                    print("⏱ Found duration \(Self.redactedValue(duration))")
                    break
                }
            }
        }
        
        print("📊 Fallback extraction complete: \(entities.count) entities found")
        for entity in entities {
            print("  - \(entity.fieldId): \(Self.redactedValue(entity.value)) (confidence: \(Int(entity.confidence * 100))%)")
        }
        
        let finalized = finalizeEntities(entities)
        let diagnostics = buildDiagnostics(for: finalized, originalText: text)
        let result = ExtractionResult(
            entities: finalized,
            unprocessedText: "",
            confidence: finalized.isEmpty ? 0.3 : averageConfidence(for: finalized),
            diagnostics: diagnostics.0,
            highlights: diagnostics.1
        )
        os_signpost(.end, log: metricsLog, name: "fallbackExtraction", signpostID: id)
        return result
    }

    // MARK: - KB-assisted recognition helpers
    nonisolated private static func detectSurgeonViaKnowledgeBase(in lowercasedText: String) -> (value: String, confidence: Double, alternatives: [String])? {
        let tokens = lowercasedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let windows = ngrams(tokens: tokens, minLen: 1, maxLen: 4)
        var best: (value: String, confidence: Double, alternatives: [String])?
        for w in windows {
            let res = IntelligentMatcher.matchSurgeon(w)
            if res.isKnownEntity && res.confidence >= 0.85 {
                if best == nil || res.confidence > best!.confidence {
                    best = (res.value, res.confidence, res.alternatives)
                }
            }
        }
        return best
    }

    nonisolated private static func detectProcedureViaKnowledgeBase(in lowercasedText: String) -> (value: String, confidence: Double, alternatives: [String])? {
        let tokens = lowercasedText.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        let windows = ngrams(tokens: tokens, minLen: 1, maxLen: 6)
        var best: (value: String, confidence: Double, alternatives: [String])?
        for w in windows {
            let res = IntelligentMatcher.matchProcedure(w)
            if res.isKnownEntity && res.confidence >= 0.80 {
                if best == nil || res.confidence > best!.confidence {
                    best = (res.value, res.confidence, res.alternatives)
                }
            }
        }
        return best
    }

    nonisolated private static func ngrams(tokens: [String], minLen: Int, maxLen: Int) -> [String] {
        var result: [String] = []
        let n = tokens.count
        let maxL = min(maxLen, n)
        for l in minLen...maxL {
            if l <= 0 { continue }
            for i in 0..<(n - l + 1) {
                let slice = tokens[i..<(i + l)]
                result.append(slice.joined(separator: " "))
            }
        }
        return result
    }
    
    nonisolated private static func formatTime(_ timeStr: String) -> String {
        // Extract hours and minutes from various formats
        let numbers = timeStr.components(separatedBy: CharacterSet.decimalDigits.inverted)
            .compactMap { Int($0) }
        
        if numbers.count >= 2 {
            return String(format: "%02d:%02d", numbers[0], numbers[1])
        } else if numbers.count == 1 && numbers[0] < 24 {
            return String(format: "%02d:00", numbers[0])
        }
        
        return ""
    }
    
    nonisolated private static func formatDate(_ dateStr: String) -> String {
        let s = dateStr.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // 1) Numeric date like 1/4/25 or 01-04-2025
        if let re = try? NSRegularExpression(pattern: #"(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})"#),
           let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
           let r1 = Range(m.range(at: 1), in: s), let r2 = Range(m.range(at: 2), in: s), let r3 = Range(m.range(at: 3), in: s) {
            var d = String(s[r1]); var mth = String(s[r2]); var y = String(s[r3])
            if d.count == 1 { d = "0" + d }
            if mth.count == 1 { mth = "0" + mth }
            if y.count == 2 { y = "20" + y }
            return "\(d)/\(mth)/\(y)"
        }
        // 2) Spoken month: 11 de abril de 2025
        let months = ["janeiro": "01", "fevereiro": "02", "março": "03", "abril": "04",
                      "maio": "05", "junho": "06", "julho": "07", "agosto": "08",
                      "setembro": "09", "outubro": "10", "novembro": "11", "dezembro": "12"]
        if let dayMatch = s.range(of: #"\b(\d{1,2})\b"#, options: .regularExpression) {
            let dayRaw = String(s[dayMatch])
            var day = dayRaw.count == 1 ? "0" + dayRaw : dayRaw
            for (name, num) in months where s.contains(name) {
                // Find 4-digit year if present
                var year = Calendar.current.component(.year, from: Date())
                if let yMatch = s.range(of: #"\b(\d{4})\b"#, options: .regularExpression) {
                    year = Int(String(s[yMatch])) ?? year
                }
                return "\(day)/\(num)/\(year)"
            }
        }
        return dateStr
    }
    
    nonisolated private static func formatDuration(_ durationStr: String) -> String {
        return DurationFormatter.format(durationStr)
    }
    
    private func batchRefineEntities(_ entities: [ExtractedEntity], originalTranscript: String) async -> [String: ExtractedEntity]? {
        guard isAvailable else { return nil }
        guard !entities.isEmpty else { return [:] }

        struct BatchRefinementPayload: Decodable {
            struct Item: Decodable {
                let fieldId: String
                let value: String
                let confidence: Double?
            }

            let refinements: [Item]
        }

        do {
            let session = LanguageModelSession(model: model)
            let fieldsDescription = entities.map { entity in
                "- \(entity.fieldId): valor atual \(Self.redactedValue(entity.value))"
            }.joined(separator: "\n")

            let prompt = """
            Você é um assistente encarregado de melhorar informações médicas extraídas em português.

            Para cada campo listado abaixo, devolva uma versão corrigida seguindo estas regras:
            - Nomes próprios iniciam com letra maiúscula
            - Datas no formato DD/MM/AAAA
            - Horários no formato HH:MM
            - Telefones contêm apenas números (10-11 dígitos)
            - Retorne somente os campos que puder refinar.

            CAMPOS:
            \(fieldsDescription)

            CONTEXTO:
            \(originalTranscript)

            Responda em JSON com este formato:
            {
                "refinements": [
                    {
                        "fieldId": "surgeryTime",
                        "value": "08:30",
                        "confidence": 92
                    }
                ]
            }
            """

            let response = try await session.respond(to: prompt)
            guard let data = response.content.data(using: .utf8) else { return nil }
            let decoded = try JSONDecoder().decode(BatchRefinementPayload.self, from: data)

            var result: [String: ExtractedEntity] = [:]
            for item in decoded.refinements {
                let normalizedValue = Self.capitalizeProperly(item.value.trimmingCharacters(in: .whitespacesAndNewlines))
                let confidence = min(max((item.confidence ?? 90) / 100.0, 0.0), 1.0)
                let signals = [ConfidenceSignal(source: "refine", score: confidence)]
                result[item.fieldId] = ExtractedEntity(
                    fieldId: item.fieldId,
                    value: normalizedValue,
                    confidence: confidence,
                    alternatives: [],
                    originalText: originalTranscript,
                    span: nil,
                    signals: signals
                )
            }
            return result
        } catch {
            print("⚠️ Batch refinement failed: \(error)")
            return nil
        }
    }

    func refineEntity(fieldId: String, originalValue: String, context: String) async throws -> ExtractedEntity? {
        guard isAvailable else { return nil }

        let session = LanguageModelSession(model: model)

        let prompt = """
        Refine esta informação médica extraída:
        
        Campo: \(fieldId)
        Valor original: \(originalValue)
        Contexto: \(context)
        
        Forneça uma versão melhorada seguindo as regras:
        - Nomes próprios com primeira letra maiúscula
        - Datas no formato DD/MM/AAAA
        - Horários no formato HH:MM
        - Telefones apenas números
        
        Responda apenas com o valor refinado, sem explicações.
        """
        
        do {
            let response = try await session.respond(to: prompt)
            let refinedValue = Self.capitalizeProperly(response.content.trimmingCharacters(in: .whitespacesAndNewlines))
            
            return ExtractedEntity(
                fieldId: fieldId,
                value: refinedValue,
                confidence: 0.9,
                alternatives: [originalValue],
                originalText: context,
                span: nil,
                signals: [ConfidenceSignal(source: "refine", score: 0.9)]
            )
        } catch {
            return nil
        }
    }

    func refineEntities(_ entities: [ExtractedEntity]) async -> [String: ExtractedEntity] {
        guard !entities.isEmpty else { return [:] }
        let transcript = entities.first?.originalText ?? ""
        if let batch = await batchRefineEntities(entities, originalTranscript: transcript) {
            return batch
        }

        var fallback: [String: ExtractedEntity] = [:]
        for entity in entities {
            do {
                if let refined = try await refineEntity(fieldId: entity.fieldId, originalValue: entity.value, context: entity.originalText) {
                    fallback[entity.fieldId] = refined
                }
            } catch {
                continue
            }
        }
        return fallback
    }
}

enum EntityExtractionError: LocalizedError {
    case modelUnavailable
    case sessionUnavailable
    case extractionFailed(Error)
    case invalidResponse
    case timeout
    
    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "Foundation Models não está disponível"
        case .sessionUnavailable:
            return "Sessão do modelo não está disponível"
        case .extractionFailed(let error):
            return "Falha na extração: \(error.localizedDescription)"
        case .invalidResponse:
            return "Resposta inválida do modelo"
        case .timeout:
            return "Tempo limite excedido - usando extração alternativa"
        }
    }
}
