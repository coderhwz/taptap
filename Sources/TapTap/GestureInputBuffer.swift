import Foundation
import GestureCore

enum GestureInput {
    case frame(device: AnyHashable, contacts: [Contact], time: TimeInterval)
    case pressure(stage: Int, time: TimeInterval)
    case button(down: Bool, supportsPressure: Bool, time: TimeInterval)
    case cancel
    case failure(String)
}

/// One bounded, ordered handoff shared by the contact and event-tap callbacks.
final class GestureInputBuffer {
    var onInput: ((GestureInput) -> Void)?
    private let lock = NSLock()
    private var pending: [GestureInput] = []
    private var accepting = false
    private var scheduled = false
    private var epoch = 0
    private let capacity = 256

    func open() {
        lock.lock()
        epoch += 1
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        accepting = true
        lock.unlock()
    }

    func close() {
        lock.lock()
        accepting = false
        epoch += 1
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
    }

    func discardPending() {
        lock.lock()
        epoch += 1
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
    }

    func enqueue(_ input: GestureInput) {
        lock.lock()
        guard accepting else { lock.unlock(); return }
        if pending.count == capacity {
            // Do not drop lifecycle edges and continue with a damaged gesture.
            pending = [.failure("输入处理积压，已暂停手势，请手动重新启用")]
            accepting = false
        } else {
            pending.append(input)
        }
        guard !scheduled else { lock.unlock(); return }
        scheduled = true
        let token = epoch
        lock.unlock()
        DispatchQueue.main.async { [weak self] in self?.drain(token: token) }
    }

    private func drain(token: Int) {
        lock.lock()
        guard epoch == token else { lock.unlock(); return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        scheduled = false
        lock.unlock()
        for input in batch {
            lock.lock()
            let current = epoch == token
            lock.unlock()
            guard current else { return }
            onInput?(input)
        }
    }
}
