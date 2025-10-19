import XCTest
@testable import SwiftTranscriptionSampleApp

@MainActor
final class TranscriptionProcessorTests: XCTestCase {
    func test_WhenPortugueseNumberPhraseProvided_ShouldReturnDigits() {
        let input = "setenta e dois anos"
        let processed = TranscriptionProcessor.processText(input, fieldType: .age)
        XCTAssertEqual(processed, "72")
    }
    
    func test_WhenPortugueseDatePhraseProvided_ShouldReturnNormalizedDate() {
        let input = "vinte e sete de setembro de dois mil e vinte e quatro"
        let processed = TranscriptionProcessor.processText(input, fieldType: .date)
        XCTAssertEqual(processed, "27/09/2024")
    }
    
    func test_WhenDurationSpoken_ShouldReturnHHMMFormat() {
        let input = "uma hora e quinze"
        let processed = TranscriptionProcessor.processText(input, fieldType: .duration)
        XCTAssertEqual(processed, "01:15")
    }
    
    func test_WhenPhoneDictated_ShouldStripFormatting() {
        let input = "(21) 99988-7766"
        let processed = TranscriptionProcessor.processText(input, fieldType: .phone)
        XCTAssertEqual(processed, "21999887766")
    }
}

@MainActor
final class EntityExtractorDeterministicTests: XCTestCase {
    func test_WhenStructuredFieldsPresent_ShouldLockDeterministicStage() throws {
        let transcript = try loadFixture(named: "structured_stage1")
        let stage = EntityExtractor.deterministicStagePreview(for: transcript)

        let values = Dictionary(uniqueKeysWithValues: stage.entities.map { ($0.fieldId, $0.value) })
        XCTAssertEqual(values["surgeryDate"], "14/10/2024")
        XCTAssertEqual(values["surgeryTime"], "13:30")
        XCTAssertEqual(values["patientPhone"], "31988776655")
        XCTAssertEqual(values["procedureDuration"], "02:00")

        XCTAssertFalse(stage.residualText.contains("14/10/2024"))
        XCTAssertFalse(stage.residualText.contains("13:30"))
        XCTAssertFalse(stage.residualText.contains("31988776655"))
    }

    func test_WhenDeterministicStageGeneratesSpans_ShouldExposeOffsets() throws {
        let transcript = try loadFixture(named: "structured_stage1")
        let stage = EntityExtractor.deterministicStagePreview(for: transcript)
        let phoneEntity = stage.entities.first { $0.fieldId == "patientPhone" }
        XCTAssertNotNil(phoneEntity?.span)
        if let span = phoneEntity?.span {
            XCTAssertGreaterThan(span.end, span.start)
            XCTAssertTrue(transcript.contains(span.snippet))
        }
    }

    private func loadFixture(named name: String) throws -> String {
        let currentFile = URL(fileURLWithPath: #filePath)
        let fixturesURL = currentFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        let fileURL = fixturesURL.appendingPathComponent("\(name).txt")
        return try String(contentsOf: fileURL, encoding: .utf8)
    }
}
