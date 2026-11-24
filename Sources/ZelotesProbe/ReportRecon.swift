import Foundation
import IOKit.hid
import ZelotesKit

/// Sizes and timings for the reconnaissance tools. Outside the class so they are not actor-isolated.
private enum Recon {
    /// Generous on purpose: a device may answer a feature read with more bytes than its descriptor promises.
    static let featureReadLength = 64
    static let longestInputReport = 1024
    static let pollInterval = Duration.milliseconds(250)
}

/// Developer tool: watches a device's reports and sends nothing to it. `feature` reads one feature report over
/// and over and prints only the bytes that changed; `input` prints each input report that differs from the last
/// one seen on its interface, with the report ID and the interface's usage page and usage.
@MainActor
final class ReportRecon {
    enum Mode {
        case feature(id: CFIndex)
        case input
    }

    private let mode: Mode
    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

    private var featureDevices: [(device: IOHIDDevice, id: CFIndex)] = []
    private var watchedDevices: [WatchedDevice] = []
    private var lastFeatureBytes: [UnsafeMutableRawPointer: [UInt8]] = [:]
    private var lastInputBytes: [String: (bytes: [UInt8], repeats: Int)] = [:]
    private var labels: [UnsafeMutableRawPointer: String] = [:]

    /// One interface being listened to. IOKit hands the callback a context pointer, which is this object's, so the
    /// label comes back with the report; the buffer has to outlive the registration.
    fileprivate final class WatchedDevice {
        let device: IOHIDDevice
        let label: String
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: Recon.longestInputReport)
        weak var recon: ReportRecon?

        init(device: IOHIDDevice, label: String) {
            self.device = device
            self.label = label
        }
    }

    static func run(_ mode: Mode, vendorID: Int, productID: Int) async throws {
        // Ctrl-C does not flush stdout, so piped output would otherwise never appear.
        setvbuf(stdout, nil, _IOLBF, 0)
        let recon = ReportRecon(mode: mode)
        try await recon.watch(vendorID: vendorID, productID: productID)
    }

    private init(mode: Mode) {
        self.mode = mode
    }

    private func watch(vendorID: Int, productID: Int) async throws {
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            throw MouseAccessError.accessRefused(status)
        }
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty else {
            throw MouseAccessError.notConnected
        }

        for device in devices {
            let opened = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
            if opened != kIOReturnSuccess {
                print("Note: \(label(of: device)) would not open (\(Self.hex(opened))).")
            }
        }

        switch mode {
        case .feature(let id):
            try findReadableFeatureReport(id, among: devices)
            print("Reading feature report \(id) every \(Recon.pollInterval); only changed bytes are printed. "
                + "Nothing is sent to the mouse. Stop with Ctrl-C.")
            while true {
                try await Task.sleep(for: Recon.pollInterval)
                readFeatureReports(id)
            }
        case .input:
            for device in devices {
                let watched = WatchedDevice(device: device, label: label(of: device))
                watched.recon = self
                watchedDevices.append(watched)
                IOHIDDeviceRegisterInputReportCallback(
                    device,
                    watched.buffer,
                    Recon.longestInputReport,
                    deviceInputArrived,
                    Unmanaged.passUnretained(watched).toOpaque()
                )
            }
            print("Listening to \(devices.count) interfaces; the first report of each and every change is printed. "
                + "Nothing is sent to the mouse. Press buttons, turn the wheel, move it. Stop with Ctrl-C.")
            while true {
                try await Task.sleep(for: .seconds(60))
            }
        }
    }

    private func findReadableFeatureReport(_ id: CFIndex, among devices: Set<IOHIDDevice>) throws {
        for device in devices {
            var bytes = [UInt8](repeating: 0, count: Recon.featureReadLength)
            var length = bytes.count
            let status = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, id, &bytes, &length)
            guard status == kIOReturnSuccess, length > 0 else {
                print("Note: \(label(of: device)) has no readable feature report \(id) (\(Self.hex(status))).")
                continue
            }
            featureDevices.append((device, id))
        }
        guard !featureDevices.isEmpty else {
            throw ReconError.noFeatureReport(id: id)
        }
    }

    private func readFeatureReports(_ id: CFIndex) {
        for entry in featureDevices {
            var bytes = [UInt8](repeating: 0, count: Recon.featureReadLength)
            var length = bytes.count
            guard IOHIDDeviceGetReport(entry.device, kIOHIDReportTypeFeature, id, &bytes, &length) == kIOReturnSuccess,
                  length > 0 else { continue }
            let report = Array(bytes.prefix(length))
            let key = Unmanaged.passUnretained(entry.device).toOpaque()
            let previous = lastFeatureBytes[key]
            lastFeatureBytes[key] = report
            guard let previous, previous.count == report.count else {
                printLine("id \(id)  " + Self.hexBytes(report))
                continue
            }
            let changes = zip(previous, report).enumerated().compactMap { pair -> String? in
                let (index, bytes) = (pair.offset, pair.element)
                return bytes.0 == bytes.1 ? nil : String(format: "%d: %02x -> %02x", index, bytes.0, bytes.1)
            }
            guard !changes.isEmpty else { continue }
            printLine("id \(id)  " + changes.joined(separator: ", "))
        }
    }

    fileprivate func received(_ report: [UInt8], reportID: UInt32, from label: String) {
        let key = "\(label) id \(reportID)"
        let previous = lastInputBytes[key]
        if let previous, previous.bytes == report {
            lastInputBytes[key] = (report, previous.repeats + 1)
            return
        }
        lastInputBytes[key] = (report, 0)
        let repeats = previous.map { $0.repeats > 0 ? " (unchanged ×\($0.repeats))" : "" } ?? ""
        printLine(key + repeats + "  " + Self.hexBytes(report))
    }

    private func label(of device: IOHIDDevice) -> String {
        let key = Unmanaged.passUnretained(device).toOpaque()
        if let cached = labels[key] { return cached }
        let page = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsagePageKey as CFString) as? NSNumber)?.intValue ?? 0
        let usage = (IOHIDDeviceGetProperty(device, kIOHIDPrimaryUsageKey as CFString) as? NSNumber)?.intValue ?? 0
        let label = String(format: "page 0x%04x/0x%02x", page, usage)
        labels[key] = label
        return label
    }

    private func printLine(_ text: String) {
        print(Date().formatted(date: .omitted, time: .standard) + "  " + text)
    }

    private static func hexBytes(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    private static func hex(_ status: IOReturn) -> String {
        "0x" + String(UInt32(bitPattern: status), radix: 16)
    }
}

private enum ReconError: LocalizedError {
    case noFeatureReport(id: CFIndex)

    var errorDescription: String? {
        switch self {
        case .noFeatureReport(let id):
            "No matched interface offered a readable feature report \(id)."
        }
    }
}

private func deviceInputArrived(
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
    nonisolated(unsafe) let watched = Unmanaged<ReportRecon.WatchedDevice>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { watched.recon?.received(bytes, reportID: reportID, from: watched.label) }
}
