import Foundation

/// An eight-byte configuration packet for the Zelotes T-20. Unlike the C-18, which takes whole tables as output
/// reports, the T-20 takes one command at a time as a numbered feature report: report ID 7 first, then the
/// command, its arguments and zeros.
public struct T20Command: Equatable, Sendable {
    public static let reportID: CFIndex = 7
    public static let byteCount = 8

    public let bytes: [UInt8]

    public init(command: UInt8, arguments: [UInt8] = []) {
        var bytes: [UInt8] = [UInt8(Self.reportID), command] + arguments
        bytes += [UInt8](repeating: 0, count: max(0, Self.byteCount - bytes.count))
        self.bytes = Array(bytes.prefix(Self.byteCount))
    }
}

public extension T20Command {
    /// One packet per stage, each carrying the active stage and the mask of the stages that are enabled.
    static func dpi(activeStage: Int, stage: Int, dpi: Int, enabledMask: UInt8) -> T20Command {
        let code = UInt8(dpi / T20DPISettings.dpiStep) << 4 | UInt8(0x08 + stage)
        return T20Command(command: 0x09, arguments: [UInt8(activeStage), code, enabledMask])
    }

    static func button(_ button: T20Button, action: T20ButtonAction) -> T20Command {
        T20Command(command: 0x10, arguments: [button.rawValue, action.rawValue])
    }

    static func scroll(_ mode: T20ScrollMode) -> T20Command {
        T20Command(command: 0x11, arguments: [mode.rawValue, mode.secondByte])
    }

    static func fireRate(_ interval: UInt8) -> T20Command {
        T20Command(command: 0x12, arguments: [0x00, interval])
    }

    static let lightingOff = T20Command(command: 0x13, arguments: [0x7F, 0x17])


    /// The vendor app's own "rainbow breathing" mode, whose speed is 0 to 5.
    static func rainbowBreathing(speed: UInt8) -> T20Command {
        T20Command(command: 0x13, arguments: [0x7F, 0x10 | (speed & 0x0F)])
    }

    /// One colour of the six the mouse stores for the modes that take a colour.
    static func colourSlot(_ slot: UInt8, _ colour: T20Color) -> T20Command {
        T20Command(command: 0x14, arguments: [(slot << 4) | colour.greenNibble, (colour.redNibble << 4) | colour.blueNibble])
    }

    /// The mode and brightness packet that follows the colour slots.
    static func lighting(mode: T20LightingMode, speed: UInt8, brightness: UInt8) -> T20Command {
        let value = mode.extendedValue
        return T20Command(
            command: 0x13,
            arguments: [0xFF, (value << 4 & 0xF0) | (speed & 0x0F), 0x0B, 0x0F - (brightness & 0x0F), value & 0xF0]
        )
    }
}
