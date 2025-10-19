import XCTest
@testable import SwiftTranscriptionSampleApp

final class EntityExtractorFallbackTests: XCTestCase {

    func test_FallbackExtraction_WhenNomeDoPacientePhraseUsed_ShouldExtractPatientName() throws {
        let transcript = "O nome do paciente é ana luiza ferreira, cinquenta e dois anos." +
        " Telefone 31 98888 7766. Procedimento colecistectomia marcado para amanhã."

        let result = try EntityExtractor.fallbackExtraction(from: transcript)
        let patientName = result.entities.first(where: { $0.fieldId == "patientName" })?.value

        XCTAssertEqual(patientName, "Ana Luiza Ferreira")
    }

    func test_FallbackExtraction_WhenTempoEstimadoSaid_ShouldExtractDuration() throws {
        let transcript = "Procedimento laparoscópico marcado às 14h30." +
        " Tempo estimado de uma hora e quinze minutos de duração."

        let result = try EntityExtractor.fallbackExtraction(from: transcript)
        let duration = result.entities.first(where: { $0.fieldId == "procedureDuration" })?.value

        XCTAssertEqual(duration, "01:15")
    }
}

