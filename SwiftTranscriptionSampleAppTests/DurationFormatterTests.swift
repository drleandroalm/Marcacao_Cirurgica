import XCTest
@testable import SwiftTranscriptionSampleApp

final class DurationFormatterTests: XCTestCase {
    func test_WhenUmaHoraEMeia_ShouldReturn0130() {
        XCTAssertEqual(DurationFormatter.format("uma hora e meia"), "01:30")
    }

    func test_WhenHColonM_ShouldReturnNormalized() {
        XCTAssertEqual(DurationFormatter.format("1:05"), "01:05")
        XCTAssertEqual(DurationFormatter.format("1h30"), "01:30")
    }

    func test_WhenMinutesOnly_ShouldReturn00MM() {
        XCTAssertEqual(DurationFormatter.format("45"), "00:45")
    }

    func test_WhenNumbersWithUnits_ShouldParse() {
        XCTAssertEqual(DurationFormatter.format("2 horas 15 minutos"), "02:15")
    }

    func test_WhenWordsOnly_ShouldParse() {
        XCTAssertEqual(DurationFormatter.format("duas horas"), "02:00")
    }

    func test_WhenMeiaHora_ShouldReturn0030() {
        XCTAssertEqual(DurationFormatter.format("meia hora"), "00:30")
    }

    func test_WhenHourWithoutMinuteUnits_ShouldInferMinutes() {
        XCTAssertEqual(DurationFormatter.format("duas horas e quarenta e cinco"), "02:45")
        XCTAssertEqual(DurationFormatter.format("uma hora e quinze"), "01:15")
    }

    func test_WhenCompactAbbreviationsProvided_ShouldExpand() {
        XCTAssertEqual(DurationFormatter.format("1h 45m"), "01:45")
    }

    func test_WhenMinutesOverflow_ShouldCarryToHours() {
        XCTAssertEqual(DurationFormatter.format("90 minutos"), "01:30")
    }

    func test_WhenAccentsMissing_ShouldStillParse() {
        XCTAssertEqual(DurationFormatter.format("tres horas e vinte"), "03:20")
    }

    func test_WhenSingleWordNumberProvided_ShouldDefaultToMinutes() {
        XCTAssertEqual(DurationFormatter.format("quinze"), "00:15")
    }
}

