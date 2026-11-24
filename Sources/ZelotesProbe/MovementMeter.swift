import Foundation
import IOKit.hid
import ZelotesKit

/// Reads the mouse's movement reports and prints, for each stroke, how often the mouse reported and how far
/// it moved, so the DPI and the polling rate it really uses can be checked. Sends nothing to the mouse.
@MainActor
final class MovementMeter {
    private struct Report {
        /// When the report reached the driver, in seconds.
        let sent: Double
        /// When this program got it, in seconds.
        let delivered: Double
        let x: Int
        let y: Int
    }

    private static let strokeCentimetres = 10.0
    private static let centimetresPerInch = 2.54
    private static let stillnessEndingAStroke = 0.5
    private static let fewestReportsToJudge = 20
    /// Longer gaps mean the hand slowed down, not that the mouse reports less often.
    private static let longestGapBetweenReports = 0.02
    /// Room for the reports that pile up between two deliveries, so none are dropped.
    private static let reportBufferCount = 1024

    // The C-18's mouse report, from its report descriptor: buttons, then X and Y as signed 16-bit
    // little-endian values, then wheel and horizontal scroll. It has no report ID.
    private static let reportLength = 7
    private let xOffset: Int
    private let yOffset: Int

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000
    }()

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private let vendorID: Int
    private let productID: Int
    private var warnedAboutReportLength = false
    private var sawFirstReport = false
    private var stroke: [Report] = []

    /// `reportStartsWithID` is for a mouse whose reports carry their report ID as a first byte, which shifts the
    /// movement values one byte along; the C-18 sends none.
    init(
        vendorID: Int = DeviceIdentity.vendorID,
        productID: Int = DeviceIdentity.productID,
        reportStartsWithID: Bool = false
    ) {
        self.vendorID = vendorID
        self.productID = productID
        xOffset = reportStartsWithID ? 2 : 1
        yOffset = reportStartsWithID ? 4 : 3
    }

    func run() async throws {
        // This runs until Ctrl-C, which does not flush stdout; piped output would otherwise never appear.
        setvbuf(stdout, nil, _IOLBF, 0)
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        let matching: [String: Any] = [
            kIOHIDVendorIDKey: vendorID,
            kIOHIDProductIDKey: productID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDPrimaryUsageKey: kHIDUsage_GD_Mouse,
        ]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        IOHIDManagerSetProperty(manager, kIOHIDMaxReportBufferCountKey as CFString, Self.reportBufferCount as CFNumber)
        IOHIDManagerRegisterInputReportWithTimeStampCallback(
            manager,
            reportArrived,
            Unmanaged.passUnretained(self).toOpaque()
        )
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)

        let status = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            if status == kIOReturnNotPermitted {
                print("Allow this terminal in System Settings › Privacy & Security › Input Monitoring, then run it again.")
            }
            throw MouseAccessError.accessRefused(status)
        }
        guard try await waitForDevice() else {
            throw MouseAccessError.notConnected
        }

        print("""
            Reading the mouse's movement; nothing is sent to it. Stop with Ctrl-C.
            DPI: lay a ruler beside the mouse, slide it \(Int(Self.strokeCentimetres)) cm in one straight stroke, \
            then hold it still.
            Polling rate: move the mouse fast in circles for two seconds, then hold it still.
            """)
        while true {
            try await Task.sleep(for: .milliseconds(100))
            finishStrokeIfStill()
        }
    }

    /// The manager fills its device set asynchronously, so the first look right after opening can be empty.
    private func waitForDevice() async throws -> Bool {
        for _ in 0..<40 {
            if let devices = IOHIDManagerCopyDevices(manager), CFSetGetCount(devices) > 0 {
                return true
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    fileprivate func received(_ report: [UInt8], reportID: UInt32, sentAt timeStamp: UInt64) {
        guard report.count >= Self.reportLength else { return }
        if !sawFirstReport {
            sawFirstReport = true
            let hex = report.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("First report: ID \(reportID), \(report.count) bytes: \(hex)")
        }
        if report.count != Self.reportLength, !warnedAboutReportLength {
            warnedAboutReportLength = true
            print("Note: this mouse's movement report is \(report.count) bytes, not \(Self.reportLength); the DPI "
                + "figure below assumes the C-18's layout. The report rate still counts.")
        }
        stroke.append(Report(
            sent: Double(timeStamp) * Self.secondsPerTick,
            delivered: Self.now,
            x: Self.signed16(report, at: xOffset),
            y: Self.signed16(report, at: yOffset)
        ))
    }

    private static var now: Double {
        Double(mach_absolute_time()) * secondsPerTick
    }

    private static func signed16(_ report: [UInt8], at offset: Int) -> Int {
        Int(Int16(bitPattern: UInt16(report[offset]) | UInt16(report[offset + 1]) << 8))
    }

    private func finishStrokeIfStill() {
        guard let last = stroke.last, Self.now - last.delivered >= Self.stillnessEndingAStroke else { return }
        if stroke.count >= Self.fewestReportsToJudge {
            printStroke()
        }
        stroke = []
    }

    private func printStroke() {
        let span = stroke[stroke.count - 1].sent - stroke[0].sent
        let movingGaps = Self.gapsWhileMoving(stroke.map(\.sent))
        let perSecond = movingGaps.isEmpty ? 0 : Double(movingGaps.count) / movingGaps.reduce(0, +)
        let sentGap = Self.median(movingGaps)
        let deliveredGap = Self.median(Self.gapsWhileMoving(stroke.map(\.delivered)))
        let movedX = stroke.reduce(0) { $0 + $1.x }
        let movedY = stroke.reduce(0) { $0 + $1.y }
        let counts = Double(movedX * movedX + movedY * movedY).squareRoot()
        let dpiOverStroke = counts / (Self.strokeCentimetres / Self.centimetresPerInch)
        print(Date().formatted(date: .omitted, time: .standard), terminator: "  ")
        print(String(
            format: "%5ld reports in %.2f s, %.0f a second while moving · typical gap %.2f ms ≈ %.0f Hz "
                + "(delivered every %.2f ms) · moved x %+ld, y %+ld · if that was %.0f cm: ≈ %.0f DPI",
            stroke.count,
            span,
            perSecond,
            sentGap * 1000,
            sentGap > 0 ? 1 / sentGap : 0,
            deliveredGap * 1000,
            movedX,
            movedY,
            Self.strokeCentimetres,
            dpiOverStroke
        ))
    }

    private static func gapsWhileMoving(_ times: [Double]) -> [Double] {
        zip(times.dropFirst(), times)
            .map { $0 - $1 }
            .filter { $0 <= longestGapBetweenReports }
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }
}

private func reportArrived(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    length: CFIndex,
    timeStamp: UInt64
) {
    guard let context else { return }
    let bytes = Array(UnsafeBufferPointer(start: report, count: length))
    let meter = Unmanaged<MovementMeter>.fromOpaque(context).takeUnretainedValue()
    MainActor.assumeIsolated { meter.received(bytes, reportID: reportID, sentAt: timeStamp) }
}
