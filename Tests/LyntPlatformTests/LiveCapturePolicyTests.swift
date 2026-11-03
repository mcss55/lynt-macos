import AppKit
import XCTest
@testable import LyntPlatform

final class LiveCapturePolicyTests: XCTestCase {
    func testOnlyEditableTextRolesOrExplicitEditableWebContainersAreEligible() {
        XCTAssertTrue(isEligibleEditable(role: "AXTextField", explicitlyEditable: nil, enabled: true))
        XCTAssertTrue(isEligibleEditable(role: "AXTextArea", explicitlyEditable: nil, enabled: true))
        XCTAssertTrue(isEligibleEditable(role: "AXGroup", explicitlyEditable: true, enabled: true))
        XCTAssertFalse(isEligibleEditable(role: "AXWebArea", explicitlyEditable: nil, enabled: true))
        XCTAssertFalse(isEligibleEditable(role: "AXStaticText", explicitlyEditable: nil, enabled: true))
        XCTAssertFalse(isEligibleEditable(role: "AXButton", explicitlyEditable: true, enabled: true))
        XCTAssertFalse(isEligibleEditable(role: "AXTextField", explicitlyEditable: false, enabled: true))
        XCTAssertFalse(isEligibleEditable(role: "AXTextField", explicitlyEditable: true, enabled: false))
    }

    func testChromiumPrimingIsRestrictedToKnownBrowserOrElectronBundles() {
        XCTAssertTrue(isChromiumFamily(bundleIdentifier: "com.google.Chrome", bundleURL: nil))
        XCTAssertTrue(isChromiumFamily(bundleIdentifier: "com.microsoft.edgemac", bundleURL: nil))
        XCTAssertFalse(isChromiumFamily(bundleIdentifier: "com.apple.TextEdit", bundleURL: nil))
        XCTAssertFalse(isChromiumFamily(bundleIdentifier: "com.example.Unknown", bundleURL: nil))
    }

    func testReadOnlyDocumentsAndTerminalSelectionAreNotAutomaticEditableEvidence() {
        XCTAssertFalse(hasAutomaticEditingEvidence(explicitlyEditable: nil, valueSettable: false, selectedTextSettable: false))
        XCTAssertFalse(hasAutomaticEditingEvidence(explicitlyEditable: false, valueSettable: true, selectedTextSettable: true))
        XCTAssertTrue(hasAutomaticEditingEvidence(explicitlyEditable: true, valueSettable: false, selectedTextSettable: false))
        XCTAssertTrue(hasAutomaticEditingEvidence(explicitlyEditable: nil, valueSettable: true, selectedTextSettable: false))
        XCTAssertTrue(hasAutomaticEditingEvidence(explicitlyEditable: nil, valueSettable: false, selectedTextSettable: true))
    }

    func testSecureRolesAndProtectedAncestorSignalsAreRejected() {
        XCTAssertTrue(isSecureRole(role: "AXTextField", subrole: "AXSecureTextField", protectedContent: nil))
        XCTAssertTrue(isSecureRole(role: "AXPasswordField", subrole: "", protectedContent: nil))
        XCTAssertTrue(isSecureRole(role: "AXGroup", subrole: "", protectedContent: true))
        XCTAssertFalse(isSecureRole(role: "AXTextField", subrole: "AXSearchField", protectedContent: false))
    }

    func testLiveReplacementChangesOnlySmallestGraphemeSafeRange() throws {
        let original = "🙂 He don't know the answer.\r\n`private_code` remains untouched."
        let desired = "🙂 He doesn't know the answer.\r\n`private_code` remains untouched."
        let edit = try XCTUnwrap(minimalReplacement(original: original, replacement: desired))
        XCTAssertEqual(edit.range.length, 0)
        XCTAssertEqual(edit.text, "es")
        XCTAssertEqual((original as NSString).replacingCharacters(in: edit.range, with: edit.text), desired)
    }

    func testLiveReplacementDoesNotTreatCanonicalUnicodeChangesAsIdentical() throws {
        let original = "A café is nearby."
        let desired = "A cafe\u{301} is nearby."
        let edit = try XCTUnwrap(minimalReplacement(original: original, replacement: desired))
        XCTAssertEqual((original as NSString).substring(with: edit.range), "é")
        XCTAssertTrue(edit.text.utf16.elementsEqual("e\u{301}".utf16))
        XCTAssertTrue((original as NSString).replacingCharacters(in: edit.range, with: edit.text).utf16.elementsEqual(desired.utf16))
    }

    func testLiveReplacementSupportsInsertionDeletionAndIdentity() throws {
        XCTAssertNil(minimalReplacement(original: "He knows.", replacement: "He knows."))
        let insertion = try XCTUnwrap(minimalReplacement(original: "Hello world", replacement: "Hello, world"))
        XCTAssertEqual(insertion.range.length, 0)
        XCTAssertEqual(insertion.text, ",")
        let deletion = try XCTUnwrap(minimalReplacement(original: "Hello, world", replacement: "Hello world"))
        XCTAssertEqual(deletion.text, "")
        XCTAssertEqual(("Hello, world" as NSString).substring(with: deletion.range), ",")
    }

    func testExactUTF16MatchIsRequiredForStableLiveTargets() {
        XCTAssertTrue(exactTextMatch("It are not compatible. Ok!", "It are not compatible. Ok!"))
        XCTAssertFalse(exactTextMatch("It are not compatible. Ok!", "It is not compatible. Ok!"))
        XCTAssertFalse(exactTextMatch("cafe\u{0301}", "caf\u{00E9}"))
    }

    func testStandardFormControlsPreferFullValueWritesOverSelectedRange() {
        XCTAssertEqual(
            liveWriteStrategy(role: "AXTextField", hasWindow: true, valueSettable: true,
                              selectedRangeSettable: true, selectedTextSettable: true, selectionValid: true),
            .fullValue
        )
        XCTAssertEqual(
            liveWriteStrategy(role: "AXTextArea", hasWindow: true, valueSettable: true,
                              selectedRangeSettable: true, selectedTextSettable: true, selectionValid: true),
            .fullValue
        )
        XCTAssertEqual(
            liveWriteStrategy(role: "AXGroup", hasWindow: true, valueSettable: false,
                              selectedRangeSettable: true, selectedTextSettable: true, selectionValid: true),
            .liveRange
        )
        XCTAssertNil(
            liveWriteStrategy(role: "AXGroup", hasWindow: true, valueSettable: false,
                              selectedRangeSettable: false, selectedTextSettable: false, selectionValid: false)
        )
    }

    func testCommandPaletteAndDialogShellsAreRecognizedForNestedSearch() {
        XCTAssertTrue(isFocusShell(role: "AXGroup", subrole: ""))
        XCTAssertTrue(isFocusShell(role: "AXDialog", subrole: ""))
        XCTAssertTrue(isFocusShell(role: "AXList", subrole: ""))
        XCTAssertTrue(isFocusShell(role: "AXComboBox", subrole: ""))
        XCTAssertTrue(isFocusShell(role: "AXGroup", subrole: "AXDialog"))
        XCTAssertFalse(isFocusShell(role: "AXButton", subrole: ""))
        XCTAssertFalse(isFocusShell(role: "AXStaticText", subrole: ""))
    }
}
