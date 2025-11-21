import XCTest
@testable import SwiftTranscriptionSampleApp

final class MilitaryTimeFormatterTests: XCTestCase {
    func test_WhenNumericCompactProvided_ShouldReturnHHMM() {
        XCTAssertEqual(MilitaryTimeFormatter.format("730"), "07:30")
        XCTAssertEqual(MilitaryTimeFormatter.format("1430"), "14:30")
    }

    func test_WhenHHMMProvided_ShouldRemainHHMM() {
        XCTAssertEqual(MilitaryTimeFormatter.format("07:05"), "07:05")
        XCTAssertEqual(MilitaryTimeFormatter.format("22:40"), "22:40")
    }

    func test_WhenPortuguesePeriodExpressionsProvided_ShouldMapCorrectly() {
        XCTAssertEqual(MilitaryTimeFormatter.format("duas da tarde"), "14:00")
        XCTAssertEqual(MilitaryTimeFormatter.format("onze e meia da noite"), "23:30")
        XCTAssertEqual(MilitaryTimeFormatter.format("meio dia e quinze"), "12:15")
        XCTAssertEqual(MilitaryTimeFormatter.format("meia noite"), "00:00")
    }

    func test_WhenAccentsMissingOrPrefixesUsed_ShouldNormalize() {
        XCTAssertEqual(MilitaryTimeFormatter.format("as sete e meia da manha"), "07:30")
        XCTAssertEqual(MilitaryTimeFormatter.format("por volta das nove da noite"), "21:00")
    }
}

