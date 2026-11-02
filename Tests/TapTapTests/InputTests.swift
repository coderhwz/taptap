import XCTest
import GestureCore
@testable import TapTap

final class InputTests: XCTestCase {
    func testLiveTrackpadCallbackCanStartAndStop() throws {
        guard ProcessInfo.processInfo.environment["TAPTAP_LIVE_INPUT_TESTS"] == "1" else {
            throw XCTSkip("Live device access is opt-in; regular tests replay input without installing listeners")
        }
        let reader = TrackpadReader()
        var deviceChanges = 0
        reader.onDevicesChanged = { deviceChanges += 1 }
        guard reader.start() else { throw XCTSkip(reader.error ?? "No trackpad") }
        defer { reader.stop() }
        XCTAssertGreaterThan(reader.deviceCount, 0)
        let deviceCount = reader.deviceCount
        XCTAssertTrue(reader.start())
        XCTAssertEqual(reader.deviceCount, deviceCount)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(deviceChanges, 0, "The initial device snapshot must not trigger a restart loop")
        reader.stop()
        XCTAssertEqual(reader.deviceCount, 0)
        XCTAssertTrue(reader.start())
        XCTAssertEqual(reader.deviceCount, deviceCount)
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(deviceChanges, 0)
    }

    func testEightBindingsAreIndependentAndOldKeysArePreserved() {
        let suite = "TapTapTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("closeTab", forKey: "gesture.threeDouble")
        let settings = GestureSettings(defaults: defaults)
        XCTAssertEqual(GestureBinding.allCases.count, 8)
        for fingers in [2, 3] {
            for kind in [TapKind.single, .double] {
                let light = GestureBinding.binding(fingers: fingers, kind: kind)
                let press = GestureBinding.binding(fingers: fingers, kind: kind, isPress: true)
                XCTAssertNotEqual(light, press)
                XCTAssertEqual(settings.action(for: press), .none)
                settings.setAction(.closeWindow, for: press)
                XCTAssertEqual(settings.action(for: light), light == .threeDouble ? .closeTab : .none)
                XCTAssertEqual(settings.action(for: press), .closeWindow)
            }
        }
        XCTAssertEqual(GestureSettings(defaults: defaults).action(for: .threeDouble), .closeTab)
        settings.restoreDefaults()
        for binding in GestureBinding.allCases {
            XCTAssertEqual(settings.action(for: binding), binding == .threeDouble ? .closeWindow : .none)
        }
    }

    private func frame(states: [Int32], x: Float = 0.4) -> [Contact]? {
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: max(96, states.count * 96), alignment: 8)
        defer { bytes.deallocate() }
        bytes.initializeMemory(as: UInt8.self, repeating: 0, count: max(96, states.count * 96))
        for (index, state) in states.enumerated() {
            let record = bytes.advanced(by: index * 96)
            record.storeBytes(of: Int32(index), toByteOffset: 16, as: Int32.self)
            record.storeBytes(of: state, toByteOffset: 20, as: Int32.self)
            record.storeBytes(of: x, toByteOffset: 32, as: Float.self)
            record.storeBytes(of: Float(0.5), toByteOffset: 36, as: Float.self)
        }
        return TrackpadReader.decode(bytes, count: states.count)
    }

    func testContactLifecycleDoesNotRequirePressureOrMouseClick() {
        for count in [2, 3] {
            var recognizer = TapRecognizer(fingerCount: count)
            let touching = frame(states: Array(repeating: 3, count: count))!
            let lifted = frame(states: Array(repeating: 5, count: count))!
            XCTAssertEqual(recognizer.process(touching, at: 1), [])
            XCTAssertEqual(recognizer.process(lifted, at: 1.08), [])
            XCTAssertEqual(recognizer.process(touching, at: 1.2), [])
            XCTAssertEqual(recognizer.process(lifted, at: 1.28), [.double])
        }
    }

    func testHoverAndLingeringAreNotActiveContacts() {
        XCTAssertEqual(frame(states: [0, 1, 2, 6, 7])?.count, 0)
        XCTAssertEqual(frame(states: [3, 4, 5])?.map(\.phase), [.active, .active, .ended])
    }

    func testInvalidPrivateABIIsRejected() {
        XCTAssertNil(frame(states: [99]))
        XCTAssertNil(frame(states: [4], x: .nan))
        XCTAssertNil(frame(states: [4], x: 4))
        XCTAssertNil(TrackpadReader.decode(nil, count: 3))
        XCTAssertNil(TrackpadReader.decode(nil, count: 17))
        XCTAssertEqual(TrackpadReader.decode(nil, count: 0)?.count, 0)
    }
}
