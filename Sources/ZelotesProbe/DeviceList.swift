import Foundation
import IOKit.hid

/// Developer tool: prints every HID interface macOS can see, one block each, so a mouse the app does not know
/// yet can be identified by inspection — its vendor and product IDs, the usage page of its configuration
/// interface, and its report sizes. Opens the devices read-only and sends nothing to them.
enum DeviceList {
    /// How much of the report descriptor to print. The descriptors of mice are well under this.
    private static let descriptorBytesShown = 400

    static func run(filter: String?) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, nil)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        defer { IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone)) }

        // Opening every interface at once is refused without Input Monitoring, but the manager matches the
        // devices anyway, and their properties are all this tool needs.
        _ = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

        let devices = (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> ?? []).sorted(by: before)
        guard !devices.isEmpty else {
            print("No HID interfaces were matched. Grant this terminal Input Monitoring in System Settings › "
                + "Privacy & Security, then run it again.")
            return
        }
        let needle = filter?.lowercased()
        var shown = 0
        for device in devices {
            let product = string(device, kIOHIDProductKey) ?? "(no product name)"
            let manufacturer = string(device, kIOHIDManufacturerKey) ?? ""
            if let needle,
               !product.lowercased().contains(needle),
               !manufacturer.lowercased().contains(needle) {
                continue
            }
            shown += 1
            print(describe(device, product: product, manufacturer: manufacturer))
        }
        print("\(shown) of \(devices.count) HID interfaces shown.")
    }

    private static func describe(_ device: IOHIDDevice, product: String, manufacturer: String) -> String {
        let title = manufacturer.isEmpty ? product : "\(product) — \(manufacturer)"
        var lines = [
            title,
            "  vendor \(hex(int(device, kIOHIDVendorIDKey)))  product \(hex(int(device, kIOHIDProductIDKey)))"
                + "  location \(hex(int(device, kIOHIDLocationIDKey)))",
            "  usage page \(hex(int(device, kIOHIDPrimaryUsagePageKey)))"
                + "  usage \(hex(int(device, kIOHIDPrimaryUsageKey)))",
            "  reports, longest: input \(int(device, kIOHIDMaxInputReportSizeKey) ?? 0)"
                + "  output \(int(device, kIOHIDMaxOutputReportSizeKey) ?? 0)"
                + "  feature \(int(device, kIOHIDMaxFeatureReportSizeKey) ?? 0)",
        ]
        if let descriptor = IOHIDDeviceGetProperty(device, kIOHIDReportDescriptorKey as CFString) as? Data {
            lines.append("  descriptor \(descriptor.count) bytes: \(hexBytes(Array(descriptor)))")
        }
        return lines.joined(separator: "\n")
    }

    private static func before(_ first: IOHIDDevice, _ second: IOHIDDevice) -> Bool {
        let key = { (device: IOHIDDevice) in
            [
                int(device, kIOHIDVendorIDKey) ?? 0,
                int(device, kIOHIDProductIDKey) ?? 0,
                int(device, kIOHIDPrimaryUsagePageKey) ?? 0,
                int(device, kIOHIDPrimaryUsageKey) ?? 0,
                int(device, kIOHIDLocationIDKey) ?? 0,
            ]
        }
        return key(first).lexicographicallyPrecedes(key(second))
    }

    private static func int(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    private static func string(_ device: IOHIDDevice, _ key: String) -> String? {
        IOHIDDeviceGetProperty(device, key as CFString) as? String
    }

    private static func hex(_ value: Int?) -> String {
        value.map { String(format: "0x%04x", $0) } ?? "—"
    }

    private static func hexBytes(_ bytes: [UInt8]) -> String {
        let shown = bytes.prefix(descriptorBytesShown).map { String(format: "%02x", $0) }.joined(separator: " ")
        return bytes.count > descriptorBytesShown ? shown + " …" : shown
    }
}
