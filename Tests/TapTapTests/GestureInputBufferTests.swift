import XCTest
@testable import TapTap

final class GestureInputBufferTests: XCTestCase {
    func testOrderedHandoffPreservesEveryEdge() {
        let buffer = GestureInputBuffer()
        let done = expectation(description: "ordered input")
        var stages: [Int] = []
        buffer.onInput = { input in
            XCTAssertTrue(Thread.isMainThread)
            if case let .pressure(stage, _) = input { stages.append(stage) }
            if stages.count == 100 { done.fulfill() }
        }
        buffer.open()
        for stage in 0..<100 { buffer.enqueue(.pressure(stage: stage, time: 0)) }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(stages, Array(0..<100))
        buffer.close()
    }

    func testOverflowDiscardsDamagedStreamAndDeliversOneFailure() {
        let buffer = GestureInputBuffer()
        let done = expectation(description: "overflow")
        var received = 0
        buffer.onInput = { input in
            received += 1
            guard case .failure = input else { return XCTFail("Damaged stream must not reach recognition") }
            done.fulfill()
        }
        buffer.open()
        for _ in 0..<1000 { buffer.enqueue(.cancel) }
        wait(for: [done], timeout: 1)
        XCTAssertEqual(received, 1)
        buffer.close()
    }

    func testCloseAndReopenRejectQueuedOldInput() {
        let buffer = GestureInputBuffer()
        let done = expectation(description: "new session")
        var stages: [Int] = []
        buffer.onInput = { input in
            if case let .pressure(stage, _) = input { stages.append(stage) }
            done.fulfill()
        }
        buffer.open()
        buffer.enqueue(.pressure(stage: 1, time: 0))
        buffer.close()
        buffer.enqueue(.pressure(stage: 2, time: 0))
        buffer.open()
        buffer.enqueue(.pressure(stage: 3, time: 0))
        wait(for: [done], timeout: 1)
        XCTAssertEqual(stages, [3])
        buffer.close()
    }
}
