import XCTest
@testable import LyntCore

final class AutomaticReviewTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    func testFingerprintIsStableAcrossCategorySetOrderAndNeverContainsSource() {
        let text = "He don't knows the private answer."
        let a = AutomaticReviewFingerprint.make(scopeID: "chrome-field-1", text: text, options: .init(enabledCategories: [.clarity, .correctness]))
        let b = AutomaticReviewFingerprint.make(scopeID: "chrome-field-1", text: text, options: .init(enabledCategories: [.correctness, .clarity]))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.count, 64)
        XCTAssertFalse(a.contains(text))
    }

    func testFingerprintDistinguishesFieldSourceOptionsAndExactUnicode() {
        let original = AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.", options: .init())
        let variants = [
            AutomaticReviewFingerprint.make(scopeID: "field-2", text: "The café is good.", options: .init()),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The cafe\u{301} is good.", options: .init()),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.\r\n", options: .init()),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.", options: .init(tone: .init(target: .professional))),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.", options: .init(enabledCategories: [.correctness])),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.", options: .init(contextKind: .search)),
            AutomaticReviewFingerprint.make(scopeID: "field-1", text: "The café is good.", options: .init(forceEnglish: true))
        ]
        for variant in variants { XCTAssertNotEqual(original, variant) }
    }

    func testRepeatedFocusAndCaretNotificationsCannotResendSameFingerprint() {
        var policy = AutomaticReviewPolicy()
        XCTAssertEqual(policy.begin(fingerprint: "same", now: epoch), .allowed)
        XCTAssertEqual(policy.begin(fingerprint: "same", now: epoch.addingTimeInterval(1)), .inFlight)
        policy.complete(fingerprint: "same")
        XCTAssertEqual(policy.begin(fingerprint: "same", now: epoch.addingTimeInterval(90)), .duplicate)
        XCTAssertEqual(policy.begin(fingerprint: "edited", now: epoch.addingTimeInterval(90)), .allowed)
    }

    func testCancelledOrFailedAttemptIsSuppressedAndLateCompletionDoesNotFreeNewSlot() {
        var policy = AutomaticReviewPolicy(minimumInterval: 0)
        XCTAssertEqual(policy.begin(fingerprint: "old", now: epoch), .allowed)
        policy.cancelInFlight()
        XCTAssertEqual(policy.begin(fingerprint: "old", now: epoch), .duplicate)
        XCTAssertEqual(policy.begin(fingerprint: "new", now: epoch), .allowed)
        policy.complete(fingerprint: "old")
        XCTAssertEqual(policy.activeFingerprint, "new")
        XCTAssertEqual(policy.begin(fingerprint: "third", now: epoch), .inFlight)
    }

    func testCooldownCandidateCanBeRetriedWithoutBeingMarkedDuplicate() {
        var policy = AutomaticReviewPolicy(minimumInterval: 4)
        XCTAssertEqual(policy.begin(fingerprint: "a", now: epoch), .allowed)
        policy.complete(fingerprint: "a")
        XCTAssertEqual(policy.begin(fingerprint: "b", now: epoch.addingTimeInterval(1)), .throttled(retryAfter: 3))
        XCTAssertEqual(policy.begin(fingerprint: "b", now: epoch.addingTimeInterval(4)), .allowed)
    }

    func testRollingRequestCapIncludesFailuresAndExpires() {
        var policy = AutomaticReviewPolicy(minimumInterval: 0, maxRequestsPerMinute: 2)
        XCTAssertEqual(policy.begin(fingerprint: "a", now: epoch), .allowed)
        policy.complete(fingerprint: "a")
        XCTAssertEqual(policy.begin(fingerprint: "b", now: epoch.addingTimeInterval(2)), .allowed)
        policy.cancelInFlight()
        XCTAssertEqual(policy.begin(fingerprint: "c", now: epoch.addingTimeInterval(10)), .throttled(retryAfter: 50))
        XCTAssertEqual(policy.begin(fingerprint: "c", now: epoch.addingTimeInterval(60)), .allowed)
    }

    func testLongCooldownDoesNotDisappearWhenRollingRateWindowExpires() {
        var policy = AutomaticReviewPolicy(minimumInterval: 120)
        XCTAssertEqual(policy.begin(fingerprint: "a", now: epoch), .allowed)
        policy.complete(fingerprint: "a")
        XCTAssertEqual(policy.begin(fingerprint: "b", now: epoch.addingTimeInterval(61)), .throttled(retryAfter: 59))
        XCTAssertEqual(policy.begin(fingerprint: "b", now: epoch.addingTimeInterval(120)), .allowed)
    }

    func testDismissedInputWaitsUntilEditedAndHistoryIsBounded() {
        var policy = AutomaticReviewPolicy(minimumInterval: 0, historyLimit: 2)
        policy.suppress(fingerprint: "dismissed")
        XCTAssertEqual(policy.begin(fingerprint: "dismissed", now: epoch), .duplicate)
        policy.suppress(fingerprint: "newer")
        policy.suppress(fingerprint: "latest")
        XCTAssertEqual(policy.begin(fingerprint: "dismissed", now: epoch), .allowed)
    }

    func testLocalPreparationIsRequiredAndShortEligibleEnglishStillAllowed() {
        for original in ["Bu xəta niyə baş verir?", "Bu hatayı nasıl düzeltebilirim?", "```swift\nlet token = \"private\"\n```", "https://example.test", "500 123"] {
            XCTAssertFalse(AutomaticReviewPolicy.eligible(request: ProtectionEngine().prepare(original).request(options: .init())), original)
        }
        let short = ProtectionEngine().prepare("He is good.").request(options: .init())
        XCTAssertTrue(AutomaticReviewPolicy.eligible(request: short))
        let disabled = ProtectionEngine().prepare("He don't knows the answer.").request(options: .init(enabledCategories: []))
        XCTAssertFalse(AutomaticReviewPolicy.eligible(request: disabled))
    }

    func testResetStartsNewSession() {
        var policy = AutomaticReviewPolicy()
        XCTAssertEqual(policy.begin(fingerprint: "same", now: epoch), .allowed)
        policy.reset()
        XCTAssertNil(policy.activeFingerprint)
        XCTAssertEqual(policy.begin(fingerprint: "same", now: epoch), .allowed)
    }
}
