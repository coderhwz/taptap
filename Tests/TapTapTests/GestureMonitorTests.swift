import AppKit
import XCTest
import GestureCore
@testable import TapTap

final class GestureMonitorTests: XCTestCase {
    private var suite: String!
    private var settings: GestureSettings!
    private var monitor: GestureMonitor!
    private var emitted: [GestureBinding] = []
    private var time: TimeInterval { ProcessInfo.processInfo.systemUptime }

    override func setUp() {
        suite = "TapTapMonitorTests.\(UUID().uuidString)"
        settings = GestureSettings(defaults: UserDefaults(suiteName: suite)!)
        for binding in GestureBinding.allCases { settings.setAction(.none, for: binding) }
        monitor = GestureMonitor(settings: settings)
        monitor.onGesture = { [weak self] in self?.emitted.append($0) }
        emitted = []
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }

    private func frame(_ count: Int, at time: TimeInterval, device: Int = 1, offset: CGFloat = 0) {
        let contacts = (0..<count).map {
            Contact(id: $0, position: CGPoint(x: 0.3 + CGFloat($0) * 0.1 + offset, y: 0.5))
        }
        monitor.receive(.frame(device: AnyHashable(device), contacts: contacts, time: time))
    }

    private func finishRelease() {
        let done = expectation(description: "Deferred release")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    func testAllEightCombinationsWithoutInstallingLiveListeners() {
        for binding in GestureBinding.allCases {
            monitor.reset()
            emitted.removeAll()
            for item in GestureBinding.allCases { settings.setAction(.none, for: item) }
            settings.setAction(.closeWindow, for: binding)
            let start = time
            for index in 0..<(binding.kind == .double ? 2 : 1) {
                let t = start + Double(index) * 0.15
                frame(binding.fingers, at: t)
                if binding.isPress {
                    monitor.receive(.pressure(stage: 1, time: t + 0.01))
                    monitor.receive(.pressure(stage: 0, time: t + 0.07))
                }
                frame(0, at: t + 0.08)
                finishRelease()
            }
            XCTAssertEqual(emitted, [binding], binding.title)
        }
    }

    func testPressureCapableMouseEventsCannotTurnLightTouchIntoPress() {
        settings.setAction(.closeWindow, for: .threeSingle)
        settings.setAction(.closeWindow, for: .threePressSingle)
        let t = time
        frame(3, at: t)
        monitor.receive(.button(down: true, supportsPressure: true, time: t + 0.01))
        monitor.receive(.button(down: false, supportsPressure: true, time: t + 0.03))
        frame(0, at: t + 0.08)
        finishRelease()
        XCTAssertEqual(emitted, [.threeSingle])
    }

    func testDoublePressWithFingersHeldSuppressesBothLightAndPressSingle() {
        for item in [.threeSingle, .threeDouble, .threePressSingle, .threePressDouble] as [GestureBinding] {
            settings.setAction(.closeWindow, for: item)
        }
        let t = time
        frame(3, at: t)
        monitor.receive(.pressure(stage: 1, time: t + 0.01))
        monitor.receive(.pressure(stage: 0, time: t + 0.06))
        frame(3, at: t + 0.14)
        monitor.receive(.pressure(stage: 1, time: t + 0.15))
        monitor.receive(.pressure(stage: 0, time: t + 0.20))
        frame(0, at: t + 0.21)
        finishRelease()
        monitor.flushPending(at: t + 2)
        XCTAssertEqual(emitted, [.threePressDouble])
        XCTAssertEqual(monitor.pressCount, 2)
    }

    func testForceStageTransitionsAreOnePress() {
        settings.setAction(.closeWindow, for: .twoPressSingle)
        let t = time
        frame(2, at: t)
        for (offset, stage) in [1, 1, 2, 2, 1, 0].enumerated() {
            monitor.receive(.pressure(stage: stage, time: t + Double(offset + 1) * 0.01))
        }
        XCTAssertEqual(emitted, [.twoPressSingle])
        XCTAssertEqual(monitor.pressCount, 1)
    }

    func testPressureCanArriveJustBeforeRawContacts() {
        settings.setAction(.closeWindow, for: .threePressSingle)
        settings.setAction(.closeWindow, for: .threeSingle)
        let t = time
        monitor.receive(.pressure(stage: 1, time: t))
        frame(3, at: t + 0.01)
        monitor.receive(.pressure(stage: 0, time: t + 0.06))
        frame(0, at: t + 0.08)
        finishRelease()
        XCTAssertEqual(emitted, [.threePressSingle])
    }

    func testLegacyClickAndLiftDoNotAlsoEmitLightTouch() {
        settings.setAction(.closeWindow, for: .twoSingle)
        settings.setAction(.closeWindow, for: .twoPressSingle)
        let t = time
        frame(2, at: t)
        monitor.receive(.button(down: true, supportsPressure: false, time: t + 0.01))
        monitor.receive(.button(down: false, supportsPressure: false, time: t + 0.05))
        frame(0, at: t + 0.08)
        finishRelease()
        XCTAssertEqual(emitted, [.twoPressSingle])
    }

    func testTapToClickAfterLiftIsNotAPress() {
        settings.setAction(.closeWindow, for: .twoSingle)
        settings.setAction(.closeWindow, for: .twoPressSingle)
        let t = time
        frame(2, at: t)
        frame(0, at: t + 0.06)
        monitor.receive(.button(down: true, supportsPressure: false, time: t + 0.07))
        monitor.receive(.button(down: false, supportsPressure: false, time: t + 0.08))
        finishRelease()
        XCTAssertEqual(emitted, [.twoSingle])
    }

    func testLiftBeforePressureZeroFinishesOnlyOnePress() {
        settings.setAction(.closeWindow, for: .threePressSingle)
        let t = time
        frame(3, at: t)
        monitor.receive(.pressure(stage: 1, time: t + 0.01))
        frame(0, at: t + 0.06)
        monitor.receive(.pressure(stage: 0, time: t + 0.08))
        finishRelease()
        XCTAssertEqual(emitted, [.threePressSingle])
    }

    func testScrollMovementAndFourthFingerCancelPress() {
        settings.setAction(.closeWindow, for: .threePressSingle)
        for kind in 0..<3 {
            monitor.reset()
            let t = time
            frame(3, at: t)
            monitor.receive(.pressure(stage: 1, time: t + 0.01))
            switch kind {
            case 0: monitor.receive(.cancel)
            case 1: frame(3, at: t + 0.03, offset: 0.1)
            default: frame(4, at: t + 0.03)
            }
            monitor.receive(.pressure(stage: 0, time: t + 0.08))
            frame(0, at: t + 0.09)
            finishRelease()
        }
        XCTAssertEqual(emitted, [])
    }

    func testAmbiguousDevicesAndStaleFramesDoNotTriggerPress() {
        settings.setAction(.closeWindow, for: .threePressSingle)
        let t = time
        frame(3, at: t, device: 1)
        frame(3, at: t, device: 2)
        monitor.receive(.pressure(stage: 1, time: t + 0.01))
        monitor.receive(.pressure(stage: 0, time: t + 0.05))
        XCTAssertEqual(emitted, [])
        monitor.reset()
        frame(3, at: t)
        monitor.receive(.pressure(stage: 1, time: t + 1))
        monitor.receive(.pressure(stage: 0, time: t + 1.05))
        XCTAssertEqual(emitted, [])
    }

    func testFailureStopsAndReportsOnceWithoutRestarting() {
        var failures: [String] = []
        monitor.onFailure = { failures.append($0) }
        monitor.receive(.failure("test failure"))
        XCTAssertFalse(monitor.isRunning)
        XCTAssertEqual(monitor.inputError, "test failure")
        XCTAssertEqual(failures, ["test failure"])
    }

    func testLightDoubleSuppressesPendingSingleWithoutMouseOrPressureEvents() {
        settings.setAction(.closeWindow, for: .threeSingle)
        settings.setAction(.closeWindow, for: .threeDouble)
        let t = time
        frame(3, at: t)
        frame(0, at: t + 0.05)
        finishRelease()
        XCTAssertEqual(emitted, [])
        frame(3, at: t + 0.15)
        frame(0, at: t + 0.20)
        finishRelease()
        monitor.flushPending(at: t + 2)
        XCTAssertEqual(emitted, [.threeDouble])
        XCTAssertEqual(monitor.pressCount, 0)
    }

    func testSingleCanFlushButResetAndScrollCancelPendingSingle() {
        settings.setAction(.closeWindow, for: .twoSingle)
        settings.setAction(.closeWindow, for: .twoDouble)
        for kind in 0..<3 {
            monitor.reset()
            let t = time
            frame(2, at: t)
            frame(0, at: t + 0.05)
            finishRelease()
            if kind == 0 { monitor.reset() }
            if kind == 1 { monitor.receive(.cancel) }
            monitor.flushPending(at: t + 2)
        }
        XCTAssertEqual(emitted, [.twoSingle])
    }

    func testLongPressAndFinalMovementCannotCloseWindow() {
        settings.setAction(.closeWindow, for: .threePressSingle)
        let t = time
        frame(3, at: t)
        monitor.receive(.pressure(stage: 1, time: t + 0.01))
        monitor.receive(.pressure(stage: 0, time: t + 0.4))
        XCTAssertEqual(emitted, [])
        monitor.reset()
        frame(3, at: t)
        monitor.receive(.pressure(stage: 1, time: t + 0.01))
        let ended = (0..<3).map { (index: Int) in
            Contact(id: index, position: CGPoint(x: 0.5 + CGFloat(index) * 0.1, y: 0.5), phase: .ended)
        }
        monitor.receive(.frame(device: AnyHashable(1), contacts: ended, time: t + 0.08))
        monitor.receive(.pressure(stage: 0, time: t + 0.09))
        finishRelease()
        XCTAssertEqual(emitted, [])
    }

    func testRapidLightFramesKeepBothReleaseEdgesAndDoNotExecuteTwice() {
        settings.setAction(.closeWindow, for: .threeSingle)
        settings.setAction(.closeWindow, for: .threeDouble)
        let t = time
        frame(3, at: t)
        frame(0, at: t + 0.05)
        frame(3, at: t + 0.15)
        frame(0, at: t + 0.20)
        finishRelease()
        monitor.flushPending(at: t + 2)
        XCTAssertEqual(emitted, [.threeDouble])
    }

    func testRealThreeFingerDoubleTapWithCGType30AtEachRelease() throws {
        settings.setAction(.closeTab, for: .threeDouble)
        let url = Bundle.module.url(forResource: "three-finger-double-tap", withExtension: "json", subdirectory: "Fixtures")!
        let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [[String: Any]]
        let base = time
        for row in rows {
            let t = base + (row["t"] as! Double)
            if row["kind"] as? String == "frame" {
                let raw = row["contacts"] as! [[String: Any]]
                let contacts = raw.compactMap { c -> Contact? in
                    let state = c["state"] as! Int
                    guard [3, 4, 5].contains(state) else { return nil }
                    return Contact(id: c["id"] as! Int,
                                   position: CGPoint(x: c["x"] as! Double, y: c["y"] as! Double),
                                   phase: state == 5 ? .ended : .active)
                }
                monitor.receive(.frame(device: AnyHashable(1), contacts: contacts, time: t))
            } else {
                let type = CGEventType(rawValue: UInt32(row["cg"] as! Int))!
                let event = CGEvent(source: nil)!
                event.type = type
                if let input = GestureMonitor.decode(event, type: type, at: t) { monitor.receive(input) }
            }
        }
        finishRelease()
        XCTAssertEqual(emitted, [.threeDouble])
    }
}
