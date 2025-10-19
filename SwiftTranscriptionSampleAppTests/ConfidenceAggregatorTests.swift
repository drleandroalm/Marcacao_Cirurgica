import XCTest
@testable import SwiftTranscriptionSampleApp

final class ConfidenceAggregatorTests: XCTestCase {
    func test_WhenDeterministicSignalHigh_ShouldRaiseAggregateScore() {
        let signals = [
            ConfidenceSignal(source: "model", score: 0.72),
            ConfidenceSignal(source: "deterministic", score: 0.96),
            ConfidenceSignal(source: "knowledgeBase", score: 0.88)
        ]
        let aggregate = EntityExtractor.aggregateConfidence(signals: signals, fallback: 0.70)
        XCTAssertGreaterThan(aggregate, 0.90)
        XCTAssertLessThanOrEqual(aggregate, 1.0)
    }

    func test_WhenOnlyModelSignalPresent_ShouldRespectFallback() {
        let signals = [ConfidenceSignal(source: "model", score: 0.68)]
        let aggregate = EntityExtractor.aggregateConfidence(signals: signals, fallback: 0.62)
        XCTAssertGreaterThanOrEqual(aggregate, 0.68)
        XCTAssertLessThanOrEqual(aggregate, 0.80)
    }

    func test_FallbackExtraction_AppendsAggregateSignal() throws {
        let transcript = "Paciente João da Silva, 65 anos, telefone (31) 98877-6655. Cirurgia marcada para dia 14/10/2024 às 13:30 com duração estimada de 2 horas."
        let result = try EntityExtractor.fallbackExtraction(from: transcript)
        let phoneEntity = result.entities.first { $0.fieldId == "patientPhone" }
        XCTAssertNotNil(phoneEntity)
        XCTAssertTrue(phoneEntity?.signals.contains(where: { $0.source == "aggregate" }) ?? false)
    }
}
