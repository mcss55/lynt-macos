import XCTest
@testable import LyntPlatform

final class TextSnapshotTests: XCTestCase {
    func testEditorChangeCannotHideBehindUnicodeCanonicalEquivalence() {
        let composed = "Caf\u{00E9} 👩🏽‍💻"
        let decomposed = "Cafe\u{0301} 👩🏽‍💻"
        XCTAssertEqual(composed, decomposed, "Swift String equality intentionally normalizes for comparison")
        XCTAssertFalse(exactTextMatch(composed, decomposed), "An editor normalization is a changed source snapshot")
        XCTAssertTrue(exactTextMatch(composed, composed))
    }

    func testLineEndingChangeInvalidatesEditorSnapshot() {
        XCTAssertFalse(exactTextMatch("first\r\nsecond", "first\nsecond"))
        XCTAssertTrue(exactTextMatch("first\r\nsecond", "first\r\nsecond"))
    }

    func testMissingAccessibilityAttributeCannotMatchAnEmptySelection() {
        XCTAssertFalse(exactTextMatch(nil, ""))
        XCTAssertFalse(exactTextMatch("", nil))
        XCTAssertTrue(exactTextMatch(nil, nil))
    }
}
