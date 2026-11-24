import Foundation

/// The T-20's seven buttons, numbered as the vendor's protocol does. The event report on interface 1 uses
/// `0xF0 + rawValue`.
public enum T20Button: UInt8, CaseIterable, Codable, Sendable {
    case left = 0x01
    case wheel = 0x02
    case right = 0x03
    case sideBack = 0x04
    case sideFront = 0x05
    case topBack = 0x06
    case topFront = 0x08
}

/// What a button does. Everything but `hostKey` the mouse performs itself; a `hostKey` binding makes the mouse
/// report the press on its vendor input report instead, so it needs a host-side listener that does not exist yet.
public enum T20ButtonAction: UInt8, CaseIterable, Codable, Sendable {
    case hostKey = 0x00
    case leftClick = 0x01
    case middleClick = 0x02
    case rightClick = 0x03
    case back = 0x04
    case forward = 0x05
    case dpiCycle = 0x06
    case showDesktop = 0x07
    case doubleClick = 0x08
    case autoFire = 0x09
    case dpiUp = 0x0B
    case dpiDown = 0x0C
}

public enum T20ScrollMode: UInt8, CaseIterable, Codable, Sendable {
    case normal = 0x00
    case volume = 0x01
    case reversed = 0x02

    var secondByte: UInt8 {
        switch self {
        case .normal: 0x00
        case .volume: 0x00
        case .reversed: 0x02
        }
    }
}

public enum T20LightingMode: String, CaseIterable, Codable, Sendable {
    case off
    case steady
    case rainbowBreathing
    case breathing
    case spectrum

    /// The nibble the extended lighting packet carries for the modes that are not the vendor's own rainbow.
    var extendedValue: UInt8 {
        switch self {
        case .steady: 0x0A
        case .breathing: 0x08
        case .spectrum: 0x06
        case .off, .rainbowBreathing: 0x00
        }
    }

    /// Whether the mode is one the vendor app sends as a single packet with its own speed byte.
    var isNative: Bool {
        self == .off || self == .rainbowBreathing
    }
}

/// The mouse stores colours inverted, four bits a channel: 0xF is dark, 0x0 is full brightness.
public struct T20Color: Equatable, Codable, Sendable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// `#rrggbb`, the form the vendor app and the reference notes use.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        red = UInt8(value >> 16)
        green = UInt8(value >> 8 & 0xFF)
        blue = UInt8(value & 0xFF)
    }

    var redNibble: UInt8 { Self.nibble(red) }
    var greenNibble: UInt8 { Self.nibble(green) }
    var blueNibble: UInt8 { Self.nibble(blue) }

    private static func nibble(_ channel: UInt8) -> UInt8 {
        0x0F - channel / 16
    }
}

public struct T20Lighting: Equatable, Codable, Sendable {
    public var mode: T20LightingMode
    public var color: T20Color
    /// 0 is the slowest and 5 the fastest; the mouse has five tiers.
    public var speed: UInt8
    /// 0 to 7.
    public var brightness: UInt8

    public init(mode: T20LightingMode, color: T20Color = T20Color(red: 255, green: 0, blue: 0),
                speed: UInt8 = 0, brightness: UInt8 = 7) {
        self.mode = mode
        self.color = color
        self.speed = min(speed, 5)
        self.brightness = min(brightness, 7)
    }

    public static let factoryDefault = T20Lighting(mode: .rainbowBreathing)
}

/// Four stages of 200 to 3000 DPI in steps of 200, of which any may be disabled.
public struct T20DPISettings: Equatable, Codable, Sendable {
    public static let stageCount = 4
    public static let dpiRange = 200...3000
    public static let dpiStep = 200
    /// Every value a stage can be set to.
    public static let dpiChoices = Array(stride(from: dpiRange.lowerBound, through: dpiRange.upperBound, by: dpiStep))

    public var stages: [Int]
    public var enabled: [Bool]
    /// Zero-based.
    public var activeStage: Int

    public init(stages: [Int], enabled: [Bool]? = nil, activeStage: Int = 0) {
        precondition(stages.count == Self.stageCount, "the T-20 has \(Self.stageCount) DPI stages")
        self.stages = stages.map { min(max($0, Self.dpiRange.lowerBound), Self.dpiRange.upperBound) }
        self.enabled = enabled ?? Array(repeating: true, count: Self.stageCount)
        self.activeStage = min(max(activeStage, 0), Self.stageCount - 1)
    }

    public static let factoryDefault = T20DPISettings(stages: [600, 800, 1200, 2400], activeStage: 0)

    var enabledMask: UInt8 {
        enabled.enumerated().reduce(0) { $0 | ($1.element ? 1 << UInt8($1.offset) : 0) }
    }
}

public struct T20Settings: Equatable, Codable, Sendable {
    public var dpi: T20DPISettings
    public var lighting: T20Lighting
    public var buttons: [T20Button: T20ButtonAction]
    public var scroll: T20ScrollMode
    public var fireRate: UInt8

    public init(
        dpi: T20DPISettings = .factoryDefault,
        lighting: T20Lighting = .factoryDefault,
        buttons: [T20Button: T20ButtonAction] = Self.factoryButtons,
        scroll: T20ScrollMode = .normal,
        fireRate: UInt8 = 4
    ) {
        self.dpi = dpi
        self.lighting = lighting
        self.buttons = buttons
        self.scroll = scroll
        self.fireRate = fireRate
    }

    /// The bindings the reference notes saw on a new mouse.
    public static let factoryButtons: [T20Button: T20ButtonAction] = [
        .left: .leftClick,
        .wheel: .middleClick,
        .right: .rightClick,
        .sideFront: .forward,
        .sideBack: .back,
        .topFront: .dpiUp,
        .topBack: .dpiDown,
    ]

    /// Refuses a binding set that would leave no button clicking, which would strand the mouse.
    public var hasLeftClick: Bool {
        buttons.values.contains(.leftClick)
    }
}
