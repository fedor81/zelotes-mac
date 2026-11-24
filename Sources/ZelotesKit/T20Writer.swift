import Foundation

/// Sends T-20 settings one command at a time, spaced as the vendor app spaces them. The mouse returns a status
/// report but no confirmation of a command's effect, and it stores nothing, so `write` has to run after each
/// plug-in.
@MainActor
public struct T20Writer {
    public typealias Pause = @MainActor (Duration) async throws -> Void

    static let settleAfterCommand = Duration.milliseconds(12)
    /// How long the interface stays busy with a mode change before it takes commands again.
    static let settleAfterRefusal = Duration.milliseconds(400)

    private let transport: any ReportTransport
    private let pause: Pause

    public init(transport: any ReportTransport, pause: @escaping Pause = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        self.pause = pause
    }

    /// Sends all the settings. The mouse refuses every command for a moment after a mode packet, so that refusal
    /// is answered by sending the sequence again; every command is a plain write, so repeating one is harmless.
    public func write(_ settings: T20Settings, attempts: Int = 3) async throws {
        var attempt = 1
        while true {
            do {
                try await writeEverything(settings)
                return
            } catch {
                guard attempt < attempts, Self.isMomentaryRefusal(error) else { throw error }
                attempt += 1
                try await pause(Self.settleAfterRefusal)
            }
        }
    }

    /// Whether the error is the refusal the T-20 gives while it is still busy with the previous mode packet.
    public static func isMomentaryRefusal(_ error: any Error) -> Bool {
        guard let error = error as? MouseAccessError else { return false }
        switch error {
        case .reportRejected(let status), .accessRefused(let status):
            return status == momentaryRefusal
        case .notConnected, .writeNotConfirmed:
            return false
        }
    }

    private static let momentaryRefusal = IOReturn(bitPattern: 0xE000_02E2)

    private func writeEverything(_ settings: T20Settings) async throws {
        try await writeLighting(settings.lighting)
        try await send(.scroll(settings.scroll))
        try await send(.fireRate(settings.fireRate))
        try await writeButtons(settings.buttons)
        try await writeDPI(settings.dpi)
    }

    /// One packet per stage; every packet carries the same mask of enabled stages and the active one.
    public func writeDPI(_ dpi: T20DPISettings) async throws {
        for (stage, value) in dpi.stages.enumerated() {
            try await send(.dpi(activeStage: dpi.activeStage, stage: stage, dpi: value, enabledMask: dpi.enabledMask))
        }
    }

    public func writeLighting(_ lighting: T20Lighting) async throws {
        switch lighting.mode {
        case .off:
            try await send(.lightingOff)
        case .rainbowBreathing:
            try await send(.rainbowBreathing(speed: lighting.speed))
        case .steady, .breathing, .spectrum:
            try await writeColourSlots(lighting.color)
            // A steady colour is the extended packet with no motion; the chip has no separate static mode here.
            let speed = lighting.mode == .steady ? 0 : lighting.speed
            try await send(.lighting(mode: lighting.mode, speed: speed, brightness: lighting.brightness))
        }
    }

    /// The extended lighting packet alone, after the colour slots have been written.
    public func sendExtended(mode value: UInt8, speed: UInt8, brightness: UInt8) async throws {
        try await send(T20Command(
            command: 0x13,
            arguments: [0xFF, (value << 4 & 0xF0) | (speed & 0x0F), 0x0B, 0x0F - (brightness & 0x0F), value & 0xF0]
        ))
    }

    public func writeColourSlots(_ colour: T20Color) async throws {
        for slot in stride(from: UInt8(0), to: 0x0B, by: 2) {
            try await send(.colourSlot(slot, colour))
        }
    }

    public func writeButtons(_ buttons: [T20Button: T20ButtonAction]) async throws {
        for button in T20Button.allCases {
            guard let action = buttons[button] else { continue }
            try await writeButton(button, action: action)
        }
    }

    /// One binding on its own, for trying a button before the app writes the whole set.
    public func writeButton(_ button: T20Button, action: T20ButtonAction) async throws {
        try await writeButton(button, rawAction: action.rawValue)
    }

    /// An action byte the app does not name yet, so the vendor's other codes can be tried.
    public func writeButton(_ button: T20Button, rawAction: UInt8) async throws {
        try await send(T20Command(command: 0x10, arguments: [button.rawValue, rawAction]))
    }

    /// Sends the vendor app's single-packet lighting effect, `07 13 7f <code>`, which the chip uses for its
    /// built-in colours and effects.
    public func sendRawMode(_ code: UInt8) async throws {
        try await send(T20Command(command: 0x13, arguments: [0x7F, code]))
    }

    public func writeScroll(_ mode: T20ScrollMode) async throws {
        try await send(.scroll(mode))
    }

    public func writeFireRate(_ interval: UInt8) async throws {
        try await send(.fireRate(interval))
    }

    private func send(_ command: T20Command) async throws {
        try transport.sendFeatureReport(command.bytes)
        try await pause(Self.settleAfterCommand)
    }
}
