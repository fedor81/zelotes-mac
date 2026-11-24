import Foundation
import IOKit.hid

/// Watches the T-20's vendor interface, which is where a button bound to `hostKey` reports its press. The plain
/// mouse interface the settings go to carries the mouse's movement only.
@MainActor
public final class T20InputMonitor {
    /// Called with each input report as it arrives, with the report's ID.
    public var onReport: (@MainActor (UInt32, [UInt8]) -> Void)?
    public private(set) var isOpen = false

    private let vendorID: Int
    private let productID: Int
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private var interfaces: [WatchedInterface] = []

    public init(vendorID: Int = T20Identity.vendorID, productID: Int = T20Identity.productID) {
        self.vendorID = vendorID
        self.productID = productID
    }

    public func start() throws {
        guard !isOpen else { return }
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: T20Identity.vendorUsagePage,
            kIOHIDPrimaryUsageKey: T20Identity.vendorUsage,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, interfaceAttached, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, interfaceDetached, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        isOpen = status == kIOReturnSuccess
        guard isOpen else {
            throw MouseAccessError.accessRefused(status)
        }
    }

    fileprivate func watch(_ device: IOHIDDevice) {
        guard isOpen, !interfaces.contains(where: { $0.device == device }) else { return }
        let interface = WatchedInterface(device: device)
        interfaces.append(interface)
        interface.register { [weak self] reportID, bytes in self?.onReport?(reportID, bytes) }
    }

    fileprivate func unwatch(_ device: IOHIDDevice) {
        guard let index = interfaces.firstIndex(where: { $0.device == device }) else { return }
        interfaces.remove(at: index).stop()
    }
}

/// One interface being read. The buffer has to outlive the registration, and IOKit hands the callback this object,
/// so the report comes back with it.
private final class WatchedInterface {
    static let longestReport = 1024

    let device: IOHIDDevice
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: WatchedInterface.longestReport)
    private var receive: ((UInt32, [UInt8]) -> Void)?

    init(device: IOHIDDevice) {
        self.device = device
    }

    deinit {
        stop()
    }

    func register(_ receive: @escaping (UInt32, [UInt8]) -> Void) {
        self.receive = receive
        IOHIDDeviceRegisterInputReportCallback(
            device,
            buffer,
            Self.longestReport,
            reportArrived,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    func stop() {
        IOHIDDeviceRegisterInputReportCallback(device, buffer, Self.longestReport, nil, nil)
        receive = nil
    }

    fileprivate func received(reportID: UInt32, _ bytes: [UInt8]) {
        receive?(reportID, bytes)
    }
}

// IOKit delivers these on the run loop the manager is scheduled on, which is the main one.
private func reportArrived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    length: CFIndex
) {
    guard let context, length > 0 else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let interface = Unmanaged<WatchedInterface>.fromOpaque(context).takeUnretainedValue()
    interface.received(reportID: reportID, bytes)
}

private func interfaceAttached(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    nonisolated(unsafe) let device = device
    onMonitor(context) { $0.watch(device) }
}

private func interfaceDetached(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    nonisolated(unsafe) let device = device
    onMonitor(context) { $0.unwatch(device) }
}

private func onMonitor(_ context: UnsafeMutableRawPointer?, _ body: @MainActor (T20InputMonitor) -> Void) {
    guard let context else { return }
    let monitor = Unmanaged<T20InputMonitor>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { body(monitor) }
}
