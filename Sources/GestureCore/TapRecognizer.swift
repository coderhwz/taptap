import Foundation

public struct Contact {
    public enum Phase { case active, ended, cancelled }
    public let id: AnyHashable
    public let position: CGPoint
    public let phase: Phase

    public init(id: AnyHashable, position: CGPoint, phase: Phase = .active) {
        self.id = id
        self.position = position
        self.phase = phase
    }
}

public enum TapKind { case single, double }

/// One recognizer per finger count and physical trackpad, using normalized coordinates.
public struct TapRecognizer {
    public var doubleTapInterval: TimeInterval = 0.4
    public let fingerCount: Int
    public let singleTapEnabled: Bool
    public let doubleTapEnabled: Bool
    private let maximumDuration: TimeInterval = 0.25
    private let landingInterval: TimeInterval = 0.10
    private let maximumMovement: CGFloat = 0.035
    private var startedAt: TimeInterval?
    private var origins: [AnyHashable: CGPoint] = [:]
    private var reachedFingerCount = false
    private var lifting = false
    private var invalid = false
    private var previousTap: (time: TimeInterval, center: CGPoint)?

    public init(fingerCount: Int = 3, singleTapEnabled: Bool = false, doubleTapEnabled: Bool = true) {
        self.fingerCount = fingerCount
        self.singleTapEnabled = singleTapEnabled
        self.doubleTapEnabled = doubleTapEnabled
    }

    public mutating func reset() {
        let interval = doubleTapInterval
        self = Self(fingerCount: fingerCount, singleTapEnabled: singleTapEnabled, doubleTapEnabled: doubleTapEnabled)
        doubleTapInterval = interval
    }

    /// Wait for an in-progress second tap to lift before deciding the first was single.
    public var nextDeadline: TimeInterval? {
        guard singleTapEnabled, let previousTap else { return nil }
        return max(previousTap.time + doubleTapInterval, (startedAt ?? 0) + maximumDuration)
    }

    public mutating func flush(at time: TimeInterval) -> TapKind? {
        guard let deadline = nextDeadline, time >= deadline else { return nil }
        previousTap = nil
        return .single
    }

    public mutating func process(_ contacts: [Contact], at time: TimeInterval) -> [TapKind] {
        var events: [TapKind] = []
        if let kind = flush(at: time) { events.append(kind) }
        // Ended contacts still carry the final position: include them in movement checks.
        let active = contacts.filter { $0.phase == .active }
        if startedAt == nil {
            guard !active.isEmpty else { return events }
            startedAt = time
            if let previousTap, time - previousTap.time > doubleTapInterval {
                self.previousTap = nil
            }
        }
        guard let start = startedAt else { return events }
        for contact in contacts {
            if contact.phase == .cancelled { invalid = true }
            if let origin = origins[contact.id] {
                if hypot(contact.position.x - origin.x, contact.position.y - origin.y) > maximumMovement {
                    invalid = true
                }
            } else if contact.phase == .active {
                if lifting || time - start > landingInterval { invalid = true }
                origins[contact.id] = contact.position
            }
        }
        if origins.count > fingerCount || time - start > maximumDuration { invalid = true }
        if active.count == fingerCount { reachedFingerCount = true }
        if reachedFingerCount && active.count < fingerCount { lifting = true }
        if invalid { previousTap = nil }

        guard active.isEmpty else { return events }
        let valid = reachedFingerCount && origins.count == fingerCount && !invalid
        let center = CGPoint(
            x: origins.values.reduce(0) { $0 + $1.x } / CGFloat(max(origins.count, 1)),
            y: origins.values.reduce(0) { $0 + $1.y } / CGFloat(max(origins.count, 1))
        )
        let previous = previousTap
        reset()
        guard valid else { return events }
        if !doubleTapEnabled {
            if singleTapEnabled { events.append(.single) }
            return events
        }
        if let previous, start >= previous.time, start - previous.time <= doubleTapInterval,
           hypot(center.x - previous.center.x, center.y - previous.center.y) <= 0.08 {
            events.append(.double)
            return events
        }
        previousTap = (time, center)
        return events
    }
}
