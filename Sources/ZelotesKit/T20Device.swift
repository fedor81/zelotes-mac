import Foundation

/// Where the T-20 answers. Its configuration commands go to the plain mouse interface rather than the vendor one
/// next to it: both take the same feature reports, and the vendor interface also carries a keyboard, which macOS
/// refuses to open without Input Monitoring.
public enum T20Identity {
    public static let vendorID = 0x30FA
    public static let productID = 0x1701
    public static let configurationUsagePage = 0x01
    public static let configurationUsage = 0x02
    public static let featureReportID = T20Command.reportID
}
