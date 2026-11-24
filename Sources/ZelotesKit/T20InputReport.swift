import Foundation

/// The report the T-20 sends on its vendor interface when a button is bound to `hostKey`:
/// `06 <0xF0 + button> 00` for the press and `06 <0xF0 + button> 80` for the release, where the first byte is the
/// report ID. The mouse's own buttons send the plain mouse report instead.
public enum T20InputReport {
    public static let reportID: UInt8 = 0x06

    /// The button the report is about, and whether the report is its press. `bytes` may or may not start with the
    /// report ID, which IOKit hands over on its own as well.
    public static func buttonPress(reportID: UInt32, in bytes: [UInt8]) -> (button: T20Button, isDown: Bool)? {
        guard reportID == UInt32(Self.reportID) else { return nil }
        let payload = bytes.first == Self.reportID ? Array(bytes.dropFirst()) : bytes
        guard payload.count >= 2, payload[0] >= 0xF0,
              let button = T20Button(rawValue: payload[0] - 0xF0) else { return nil }
        return (button, payload[1] & 0x80 == 0)
    }
}
