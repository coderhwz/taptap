import AppKit
import GestureCore
import Darwin

/// The private ABI is isolated here. Copy callback memory before returning to the driver.
final class TrackpadReader {
    typealias Callback = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?, Int, Double, Int, UnsafeMutableRawPointer?) -> Void
    private typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
    private typealias Register = @convention(c) (UnsafeMutableRawPointer, Callback, UnsafeMutableRawPointer) -> Void
    private typealias Unregister = @convention(c) (UnsafeMutableRawPointer, Callback) -> Void
    private typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    private typealias Stop = @convention(c) (UnsafeMutableRawPointer) -> Int32
    private typealias Dimensions = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<Int32>, UnsafeMutablePointer<Int32>) -> Int32
    private let handle: UnsafeMutableRawPointer?
    private var deviceList: CFArray?
    private var devices: [UnsafeMutableRawPointer] = []
    private let lock = NSLock()
    private var epoch = 0
    private var accepting = false
    var onFrame: ((AnyHashable, [Contact], TimeInterval) -> Void)?
    var onError: ((String) -> Void)?
    private(set) var error: String?
    var deviceCount: Int { devices.count }

    init() {
        handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW)
        // Keep the framework loaded for the lifetime of the process, including late callbacks.
    }

    private func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let symbol = dlsym(handle, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    func start() -> Bool {
        if !devices.isEmpty { return true }
        error = nil
        guard let create = symbol("MTDeviceCreateList", as: CreateList.self),
              let register = symbol("MTRegisterContactFrameCallbackWithRefcon", as: Register.self),
              let start = symbol("MTDeviceStart", as: Start.self),
              symbol("MTDeviceStop", as: Stop.self) != nil,
              symbol("MTUnregisterContactFrameCallback", as: Unregister.self) != nil,
              let dimensions = symbol("MTDeviceGetSensorDimensions", as: Dimensions.self),
              let list = create()?.takeRetainedValue() else {
            error = "无法读取触控板接触数据：系统接口不可用"
            return false
        }
        deviceList = list
        lock.lock()
        accepting = true
        epoch += 1
        lock.unlock()
        for index in 0..<CFArrayGetCount(list) {
            let device = UnsafeMutableRawPointer(mutating: CFArrayGetValueAtIndex(list, index)!)
            var rows: Int32 = 0
            var columns: Int32 = 0
            guard dimensions(device, &rows, &columns) == 0, rows >= 10 else { continue }
            register(device, Self.callback, Unmanaged.passUnretained(self).toOpaque())
            guard start(device, 0) == 0 else {
                symbol("MTUnregisterContactFrameCallback", as: Unregister.self)?(device, Self.callback)
                continue
            }
            devices.append(device)
        }
        if devices.isEmpty { error = "没有检测到可用触控板" }
        return !devices.isEmpty
    }

    func stop() {
        lock.lock()
        accepting = false
        epoch += 1
        lock.unlock()
        let stop = symbol("MTDeviceStop", as: Stop.self)
        let unregister = symbol("MTUnregisterContactFrameCallback", as: Unregister.self)
        for device in devices {
            unregister?(device, Self.callback)
            _ = stop?(device)
        }
        devices.removeAll()
        deviceList = nil
    }

    private static let callback: Callback = { device, data, count, _, _, context in
        guard let device, let context else { return }
        let reader = Unmanaged<TrackpadReader>.fromOpaque(context).takeUnretainedValue()
        reader.lock.lock()
        let accepting = reader.accepting
        let epoch = reader.epoch
        reader.lock.unlock()
        guard accepting else { return }
        let contacts = decode(data, count: count)
        let key = AnyHashable(UInt(bitPattern: device))
        let time = ProcessInfo.processInfo.systemUptime
        reader.lock.lock()
        let current = reader.accepting && reader.epoch == epoch
        guard current else { reader.lock.unlock(); return }
        // Keep the epoch check and enqueue atomic with respect to stop/start.
        // These handlers only enqueue data; they must not synchronously stop the reader.
        defer { reader.lock.unlock() }
        guard let contacts else {
            reader.onError?("触控板数据格式不兼容，已停止识别")
            return
        }
        // The consumer copies into a bounded mailbox; never queue each frame on main.
        reader.onFrame?(key, contacts, time)
    }

    static func decode(_ data: UnsafeRawPointer?, count: Int) -> [Contact]? {
        guard (0...16).contains(count), count == 0 || data != nil else { return nil }
        var contacts: [Contact] = []
        // Current macOS contact record: 96 bytes, identity +16, lifecycle +20, position +32/+36.
        for index in 0..<count {
            let record = data!.advanced(by: index * 96)
            let id = record.load(fromByteOffset: 16, as: Int32.self)
            let state = record.load(fromByteOffset: 20, as: Int32.self)
            let x = record.load(fromByteOffset: 32, as: Float.self)
            let y = record.load(fromByteOffset: 36, as: Float.self)
            guard (0...7).contains(state), x.isFinite, y.isFinite,
                  (-0.1...1.1).contains(x), (-0.1...1.1).contains(y) else {
                return nil
            }
            // Make/touch are actual surface contact; hover and lingering are not touches.
            if state == 3 || state == 4 || state == 5 {
                contacts.append(Contact(id: id, position: CGPoint(x: CGFloat(x), y: CGFloat(y)),
                                        phase: state == 5 ? .ended : .active))
            }
        }
        return contacts
    }
}
