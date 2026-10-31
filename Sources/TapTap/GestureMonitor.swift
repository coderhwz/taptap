import AppKit
import GestureCore

final class GestureMonitor {
    var onGesture: ((GestureBinding) -> Void)?
    let settings: GestureSettings
    private(set) var generation = 0
    private var pendingTimer: DispatchWorkItem?
    private var pendingDeadline: TimeInterval?
    private struct Key: Hashable {
        let device: AnyHashable
        let fingers: Int
        var isPress = false
    }
    var onFailure: ((String) -> Void)?
    private(set) var eventCount = 0
    private(set) var gestureCount = 0
    private(set) var lastFingerCount = 0
    private var recognizers: [Key: TapRecognizer] = [:]
    private let trackpad = TrackpadReader()
    private let inputs = GestureInputBuffer()
    private var contactsByDevice: [AnyHashable: [Contact]] = [:]
    private var frameTimes: [AnyHashable: TimeInterval] = [:]
    private var suppressedDevices: Set<AnyHashable> = []
    private var pressDevice: AnyHashable?
    private var pressureStage = 0
    private var pendingPressAt: TimeInterval?
    private var releaseWork: [AnyHashable: DispatchWorkItem] = [:]
    private(set) var pressCount = 0
    private(set) var pressureEventCount = 0
    private(set) var inputError: String?
    var deviceCount: Int { trackpad.deviceCount }
    private var eventTap: CFMachPort?
    private var source: CFRunLoopSource?
    var isRunning: Bool { eventTap != nil }

    init(settings: GestureSettings) {
        self.settings = settings
        inputs.onInput = { [weak self] input in self?.receive(input) }
        trackpad.onFrame = { [weak self] device, contacts, time in
            self?.inputs.enqueue(.frame(device: device, contacts: contacts, time: time))
        }
        trackpad.onError = { [weak self] error in
            self?.inputs.enqueue(.failure(error))
        }
    }

    func start() -> Bool {
        if isRunning { return true }
        var mask: CGEventMask = 0
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown,
                     .leftMouseUp, .rightMouseUp, .otherMouseUp, .scrollWheel] {
            mask |= CGEventMask(1) << type.rawValue
        }
        // Native gestures, including pressure, travel in CG type 29. NSEvent's
        // type numbers are a different namespace and must not be used as CG masks.
        mask |= CGEventMask(1) << 29
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<GestureMonitor>.fromOpaque(context).takeUnretainedValue()
            monitor.capture(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            inputError = CGPreflightListenEventAccess() ? "无法建立输入监听，请手动重新启用"
                : "需要输入监控权限，请在菜单中授权后重新启用"
            return false
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            inputError = "无法建立输入监听运行循环"
            return false
        }
        self.eventTap = tap
        self.source = source
        reset()
        inputs.open()
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        inputError = nil
        if !trackpad.start() {
            inputError = trackpad.error
            stop()
            return false
        }
        return true
    }

    func stop() {
        inputs.close()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil
        eventTap = nil
        trackpad.stop()
        reset()
    }

    func reset(clearInputs: Bool = true) {
        if clearInputs { inputs.discardPending() }
        generation += 1
        pendingTimer?.cancel()
        pendingTimer = nil
        pendingDeadline = nil
        recognizers.removeAll()
        for work in releaseWork.values { work.cancel() }
        releaseWork.removeAll()
        contactsByDevice.removeAll()
        frameTimes.removeAll()
        suppressedDevices.removeAll()
        pressDevice = nil
        pressureStage = 0
        pendingPressAt = nil
        lastFingerCount = 0
    }

    private func capture(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            inputs.enqueue(.failure("输入监听已被系统停用，请检查权限后手动重新启用"))
            return
        }
        if let input = Self.decode(event, type: type, at: ProcessInfo.processInfo.systemUptime) {
            inputs.enqueue(input)
        }
    }

    static func decode(_ event: CGEvent, type: CGEventType, at time: TimeInterval) -> GestureInput? {
        // CG type 30 occurs on ordinary contact release. Converting it produces
        // an unsupported NSEvent whose raw type collides with NSEvent.magnify.
        guard [1, 2, 3, 4, 25, 26, 22, 29].contains(type.rawValue) else { return nil }
        guard let native = NSEvent(cgEvent: event) else { return nil }
        switch native.type {
        case .pressure:
            return .pressure(stage: native.stage, time: time)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .button(down: true, supportsPressure: native.associatedEventsMask.contains(.pressure), time: time)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            return .button(down: false, supportsPressure: native.associatedEventsMask.contains(.pressure), time: time)
        case .scrollWheel, .swipe, .magnify, .rotate:
            return .cancel
        default: return nil
        }
    }

    // Main-thread consumer. Keeping it independent of live devices allows safe replay tests.
    func receive(_ input: GestureInput) {
        switch input {
        case let .frame(device, contacts, time):
            receiveFrame(device: device, contacts: contacts, time: time)
        case let .pressure(stage, time):
            pressureEventCount += 1
            let previous = pressureStage
            pressureStage = stage
            if previous == 0 && stage > 0 {
                // The pressure and raw-contact streams can arrive in either order.
                if contactsByDevice.values.allSatisfy({ $0.isEmpty }) { pendingPressAt = time }
                beginPress(at: time)
            }
            if previous > 0 && stage == 0 {
                pendingPressAt = nil
                endPress(at: time)
            }
        case let .button(down, supportsPressure, time):
            // Legacy mechanical trackpads have no pressure events. Tap-to-click after
            // lifting is rejected by beginPress's active-contact requirement.
            guard !supportsPressure, pressureStage == 0 else { return }
            if down { beginPress(at: time) } else { endPress(at: time) }
        case .cancel:
            suppressHeldContacts()
        case let .failure(message):
            inputError = message
            stop()
            onFailure?(message)
        }
    }

    private func beginPress(at time: TimeInterval) {
        guard pressDevice == nil else { return }
        let candidates = contactsByDevice.filter {
            !$0.value.isEmpty && time - (frameTimes[$0.key] ?? 0) <= 0.1
        }
        guard !candidates.isEmpty else { return }
        // Public pressure events do not identify the raw MT device. Do not guess
        // when multiple trackpads are touched at once.
        guard candidates.count == 1, let (device, contacts) = candidates.first else {
            suppressHeldContacts()
            return
        }
        pendingPressAt = nil
        suppressedDevices.insert(device)
        releaseWork.removeValue(forKey: device)?.cancel()
        recognizers = recognizers.filter { $0.key.isPress }
        if (2...3).contains(contacts.count) {
            pressCount += 1
            pressDevice = device
            process(contacts, device: device, isPress: true, at: time)
        }
        schedulePendingSingles()
    }

    private func endPress(at time: TimeInterval) {
        guard let device = pressDevice else { return }
        pressDevice = nil
        process([], device: device, isPress: true, at: time)
        schedulePendingSingles()
    }

    private func suppressHeldContacts() {
        let held = contactsByDevice
        let times = frameTimes
        let stage = pressureStage
        reset(clearInputs: false)
        contactsByDevice = held
        frameTimes = times
        pressureStage = stage
        suppressedDevices = Set(held.filter { !$0.value.isEmpty }.keys)
    }

    private func receiveFrame(device: AnyHashable, contacts: [Contact], time: TimeInterval) {
        eventCount += 1
        frameTimes[device] = time
        let active = contacts.filter { $0.phase == .active }
        let wasTouching = !(contactsByDevice[device] ?? []).isEmpty
        contactsByDevice[device] = active
        lastFingerCount = active.count
        if let pending = pendingPressAt, !active.isEmpty {
            pendingPressAt = nil
            if pressureStage > 0, abs(time - pending) <= 0.035 {
                beginPress(at: max(time, pending))
            } else {
                suppressHeldContacts()
            }
        }
        if pressDevice == device {
            // Lifting is a release even if the pressure-zero event arrives later.
            process(contacts, device: device, isPress: true, at: time)
            if active.isEmpty { pressDevice = nil }
        }
        if active.isEmpty {
            guard wasTouching, releaseWork[device] == nil else { return }
            // Give the button stream time to invalidate light-touch recognition.
            let token = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == token else { return }
                self.releaseWork[device] = nil
                if self.suppressedDevices.remove(device) != nil { return }
                self.process(contacts, device: device, at: time)
                self.schedulePendingSingles()
            }
            releaseWork[device] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: work)
        } else {
            // An already queued release separates two rapid light taps.
            if let work = releaseWork.removeValue(forKey: device) {
                work.perform()
                work.cancel()
            }
            guard !suppressedDevices.contains(device) else {
                return
            }
            process(contacts, device: device, at: time)
        }
        schedulePendingSingles()
    }

    private func process(_ contacts: [Contact], device: AnyHashable, isPress: Bool = false, at time: TimeInterval) {
        for fingers in [2, 3] {
            let key = Key(device: device, fingers: fingers, isPress: isPress)
            var recognizer = recognizers[key] ?? makeRecognizer(fingers: fingers, isPress: isPress)
            let events = recognizer.process(contacts, at: time)
            recognizers[key] = recognizer
            if let kind = events.first { emit(fingers: fingers, kind: kind, isPress: isPress) }
        }
    }

    private func makeRecognizer(fingers: Int, isPress: Bool) -> TapRecognizer {
        let single = GestureBinding.binding(fingers: fingers, kind: .single, isPress: isPress)
        let double = GestureBinding.binding(fingers: fingers, kind: .double, isPress: isPress)
        var recognizer = TapRecognizer(fingerCount: fingers,
                                      singleTapEnabled: settings.action(for: single) != .none,
                                      doubleTapEnabled: settings.action(for: double) != .none)
        recognizer.doubleTapInterval = NSEvent.doubleClickInterval
        return recognizer
    }

    private func emit(fingers: Int, kind: TapKind, isPress: Bool) {
        let binding = GestureBinding.binding(fingers: fingers, kind: kind, isPress: isPress)
        guard settings.action(for: binding) != .none else { return }
        gestureCount += 1
        // Keep held contacts suppressed after an action; lifting cannot fire a light tap.
        suppressHeldContacts()
        onGesture?(binding)
    }

    private func schedulePendingSingles() {
        let deadline = recognizers.values.compactMap(\.nextDeadline).min()
        guard deadline != pendingDeadline else { return }
        pendingTimer?.cancel()
        pendingTimer = nil
        pendingDeadline = deadline
        guard let deadline else { return }
        let token = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == token, self.isRunning else { return }
            self.pendingTimer = nil
            self.pendingDeadline = nil
            self.flushPending(at: ProcessInfo.processInfo.systemUptime)
            self.schedulePendingSingles()
        }
        pendingTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - ProcessInfo.processInfo.systemUptime), execute: work)
    }

    func flushPending(at time: TimeInterval) {
        for key in Array(recognizers.keys) {
            if let kind = recognizers[key]!.flush(at: time) {
                emit(fingers: key.fingers, kind: kind, isPress: key.isPress)
                return
            }
        }
    }
}
