import XCTest
@testable import GestureCore

final class TapRecognizerTests: XCTestCase {
    private func contacts(_ count: Int = 3, offset: CGFloat = 0, phase: Contact.Phase = .active) -> [Contact] {
        (0..<count).map { Contact(id: $0, position: CGPoint(x: 0.3 + CGFloat($0) * 0.15 + offset, y: 0.5), phase: phase) }
    }

    @discardableResult
    private func tap(_ recognizer: inout TapRecognizer, at time: Double, count: Int = 3) -> Bool {
        XCTAssertEqual(recognizer.process(contacts(count), at: time), [])
        return recognizer.process(contacts(count, phase: .ended), at: time + 0.08) == [.double]
    }

    func testTwoTapsTriggerOnlyOnSecondRelease() {
        var r = TapRecognizer()
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertTrue(tap(&r, at: 1.2))
        XCTAssertFalse(tap(&r, at: 1.4))
        XCTAssertTrue(tap(&r, at: 1.6))
    }

    func testSingleTapAndExpiredPairDoNotTrigger() {
        var r = TapRecognizer()
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertFalse(tap(&r, at: 2))
        XCTAssertTrue(tap(&r, at: 2.2))
    }

    func testOneTwoAndFourFingersDoNotTrigger() {
        for count in [1, 2, 4] {
            var r = TapRecognizer()
            XCTAssertFalse(tap(&r, at: 1, count: count))
            XCTAssertFalse(tap(&r, at: 1.2, count: count))
        }
    }

    func testSwipeAndMovementAtReleaseRejectPair() {
        for phase in [Contact.Phase.active, .ended] {
            var r = TapRecognizer()
            XCTAssertFalse(tap(&r, at: 1))
            XCTAssertEqual(r.process(contacts(), at: 1.2), [])
            XCTAssertEqual(r.process(contacts(offset: 0.1, phase: phase), at: 1.25), [])
            XCTAssertEqual(r.process([], at: 1.28), [])
            XCTAssertFalse(tap(&r, at: 1.4))
        }
    }

    func testLongPressRejectsPair() {
        var r = TapRecognizer()
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertEqual(r.process(contacts(), at: 1.2), [])
        XCTAssertEqual(r.process([], at: 1.6), [])
        XCTAssertFalse(tap(&r, at: 1.7))
    }

    func testStaggeredLandingAndLiftingAreAllowed() {
        var r = TapRecognizer()
        XCTAssertEqual(r.process(contacts(1), at: 1), [])
        XCTAssertEqual(r.process(contacts(2), at: 1.02), [])
        XCTAssertEqual(r.process(contacts(), at: 1.04), [])
        XCTAssertEqual(r.process(contacts(2), at: 1.07), [])
        XCTAssertEqual(r.process([], at: 1.1), [])
        XCTAssertTrue(tap(&r, at: 1.25))
    }

    func testSlowLandingDoesNotBecomeTap() {
        var r = TapRecognizer()
        XCTAssertEqual(r.process(contacts(1), at: 1), [])
        XCTAssertEqual(r.process(contacts(), at: 1.15), [])
        XCTAssertEqual(r.process([], at: 1.2), [])
        XCTAssertFalse(tap(&r, at: 1.3))
    }

    func testFourthFingerInvalidatesEvenWhenLiftedBeforeOthers() {
        var r = TapRecognizer()
        XCTAssertEqual(r.process(contacts(), at: 1), [])
        XCTAssertEqual(r.process(contacts(4), at: 1.03), [])
        XCTAssertEqual(r.process(contacts(), at: 1.05), [])
        XCTAssertEqual(r.process([], at: 1.1), [])
        XCTAssertFalse(tap(&r, at: 1.25))
    }

    func testCancelledFrameAndResetDisarmPendingTap() {
        var r = TapRecognizer()
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertEqual(r.process(contacts(), at: 1.2), [])
        XCTAssertEqual(r.process(contacts(phase: .cancelled), at: 1.25), [])
        XCTAssertFalse(tap(&r, at: 1.4))
        r.reset()
        XCTAssertFalse(tap(&r, at: 1.6))
    }

    func testDistantSecondTapDoesNotTrigger() {
        var r = TapRecognizer()
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertEqual(r.process(contacts(offset: 0.2), at: 1.2), [])
        XCTAssertEqual(r.process([], at: 1.28), [])
    }

    func testEmptyTerminalFrameAndSmallJitter() {
        var r = TapRecognizer()
        XCTAssertEqual(r.process(contacts(), at: 1), [])
        XCTAssertEqual(r.process(contacts(offset: 0.005), at: 1.02), [])
        XCTAssertEqual(r.process([], at: 1.08), [])
        XCTAssertEqual(r.process(contacts(), at: 1.2), [])
        XCTAssertEqual(r.process([], at: 1.28), [.double])
    }

    func testAllFourCombinations() {
        for fingers in [2, 3] {
            var single = TapRecognizer(fingerCount: fingers, singleTapEnabled: true, doubleTapEnabled: false)
            XCTAssertEqual(single.process(contacts(fingers), at: 1), [])
            XCTAssertEqual(single.process([], at: 1.08), [.single])
            XCTAssertNil(single.nextDeadline)
            var double = TapRecognizer(fingerCount: fingers)
            XCTAssertFalse(tap(&double, at: 1, count: fingers))
            XCTAssertTrue(tap(&double, at: 1.2, count: fingers))
        }
    }

    func testSingleWaitsAndIsFlushedOnceWhenBothEnabled() {
        var r = TapRecognizer(fingerCount: 2, singleTapEnabled: true)
        XCTAssertEqual(r.process(contacts(2), at: 1), [])
        XCTAssertEqual(r.process([], at: 1.08), [])
        XCTAssertEqual(r.nextDeadline!, 1.48, accuracy: 0.001)
        XCTAssertNil(r.flush(at: 1.47))
        XCTAssertEqual(r.flush(at: 1.49), .single)
        XCTAssertNil(r.flush(at: 2))
    }

    func testDoubleSuppressesPendingSingleForBothFingerCounts() {
        for fingers in [2, 3] {
            var r = TapRecognizer(fingerCount: fingers, singleTapEnabled: true)
            XCTAssertFalse(tap(&r, at: 1, count: fingers))
            XCTAssertTrue(tap(&r, at: 1.2, count: fingers))
            XCTAssertNil(r.flush(at: 2))
        }
    }

    func testSecondTapCanFinishAfterOriginalSingleDeadline() {
        var r = TapRecognizer(singleTapEnabled: true)
        XCTAssertFalse(tap(&r, at: 1))
        XCTAssertEqual(r.process(contacts(), at: 1.45), [])
        XCTAssertNil(r.flush(at: 1.49))
        XCTAssertEqual(r.process([], at: 1.55), [.double])
        XCTAssertNil(r.flush(at: 2))
    }

    func testResetCancelsPendingSingleAndKeepsConfiguration() {
        var r = TapRecognizer(fingerCount: 2, singleTapEnabled: true)
        r.doubleTapInterval = 0.6
        XCTAssertFalse(tap(&r, at: 1, count: 2))
        r.reset()
        XCTAssertNil(r.flush(at: 2))
        XCTAssertEqual(r.fingerCount, 2)
        XCTAssertTrue(r.singleTapEnabled)
        XCTAssertEqual(r.doubleTapInterval, 0.6)
    }

    func testDisabledCombinationsNeverEmit() {
        for fingers in [2, 3] {
            var r = TapRecognizer(fingerCount: fingers, singleTapEnabled: false, doubleTapEnabled: false)
            XCTAssertFalse(tap(&r, at: 1, count: fingers))
            XCTAssertFalse(tap(&r, at: 1.2, count: fingers))
            XCTAssertNil(r.flush(at: 2))
        }
    }

    func testTwoFingerSingleRejectsThreeFingerGestureAndScrollMovement() {
        var r = TapRecognizer(fingerCount: 2, singleTapEnabled: true, doubleTapEnabled: false)
        XCTAssertEqual(r.process(contacts(2), at: 1), [])
        XCTAssertEqual(r.process(contacts(3), at: 1.02), [])
        XCTAssertEqual(r.process([], at: 1.08), [])
        XCTAssertEqual(r.process(contacts(2), at: 2), [])
        XCTAssertEqual(r.process(contacts(2, offset: 0.1), at: 2.04), [])
        XCTAssertEqual(r.process([], at: 2.08), [])
    }
}
