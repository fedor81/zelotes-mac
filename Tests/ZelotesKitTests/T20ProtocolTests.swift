import Foundation
import Testing
@testable import ZelotesKit

@Suite struct T20CommandTests {
    /// Packets as they were sent to a real T-20 and seen take effect.
    @Test func colourSlotMatchesThePacketThatLitTheMouseRed() {
        #expect(T20Command.colourSlot(0, T20Color(red: 255, green: 0, blue: 0)).bytes == [0x07, 0x14, 0x0F, 0x0F, 0, 0, 0, 0])
        #expect(T20Command.colourSlot(0, T20Color(red: 0, green: 0, blue: 255)).bytes == [0x07, 0x14, 0x0F, 0xF0, 0, 0, 0, 0])
    }

    @Test func steadyLightingMatchesThePacketThatLitTheMouseRed() {
        let command = T20Command.lighting(mode: .steady, speed: 0, brightness: 7)
        #expect(command.bytes == [0x07, 0x13, 0xFF, 0xA0, 0x0B, 0x08, 0x00, 0x00])
    }

    @Test func theNativeLightingModesMatchTheObservedPackets() {
        #expect(T20Command.lightingOff.bytes == [0x07, 0x13, 0x7F, 0x17, 0, 0, 0, 0])
        #expect(T20Command.rainbowBreathing(speed: 0).bytes == [0x07, 0x13, 0x7F, 0x10, 0, 0, 0, 0])
        #expect(T20Command.rainbowBreathing(speed: 5).bytes == [0x07, 0x13, 0x7F, 0x15, 0, 0, 0, 0])
    }

    @Test func aDPIPacketCarriesTheStageAndTheEnabledStages() {
        #expect(
            T20Command.dpi(activeStage: 0, stage: 0, dpi: 600, enabledMask: 0x0F).bytes
                == [0x07, 0x09, 0x00, 0x38, 0x0F, 0, 0, 0]
        )
        #expect(
            T20Command.dpi(activeStage: 2, stage: 3, dpi: 2400, enabledMask: 0b0101).bytes
                == [0x07, 0x09, 0x02, 0xCB, 0x05, 0, 0, 0]
        )
    }

    @Test func aPacketIsAlwaysTheReportIDSevenBytes() {
        #expect(T20Command.button(.left, action: .leftClick).bytes.count == T20Command.byteCount)
        #expect(T20Command(command: 0x09, arguments: [1, 2, 3, 4, 5, 6, 7, 8, 9]).bytes.count == T20Command.byteCount)
    }

    @Test func settingsDefaultToTheMasksAndBindingsOfAFreshMouse() {
        #expect(T20Settings().dpi.enabledMask == 0x0F)
        #expect(T20Settings().hasLeftClick)
        #expect(T20DPISettings.dpiChoices.first == 200)
        #expect(T20DPISettings.dpiChoices.last == 3000)
    }

    @Test func aBindingSetWithoutLeftClickIsRefusedByTheModelGuard() {
        var buttons = T20Settings.factoryButtons
        buttons[.left] = .back
        #expect(!T20Settings(buttons: buttons).hasLeftClick)
        #expect(T20Settings(buttons: buttons).hasLeftClick == false)
    }
}

@MainActor
@Suite struct T20WriterTests {
    @Test func sendsTheWholeSettingsInTheOrderOfTheVendorSoftware() async throws {
        let mouse = FakeT20()

        try await T20Writer(transport: mouse, pause: { _ in }).write(T20Settings())

        #expect(mouse.packets == [
            [0x07, 0x13, 0x7F, 0x10, 0, 0, 0, 0],
            [0x07, 0x11, 0x00, 0x00, 0, 0, 0, 0],
            [0x07, 0x12, 0x00, 0x04, 0, 0, 0, 0],
            [0x07, 0x10, 0x01, 0x01, 0, 0, 0, 0],
            [0x07, 0x10, 0x02, 0x02, 0, 0, 0, 0],
            [0x07, 0x10, 0x03, 0x03, 0, 0, 0, 0],
            [0x07, 0x10, 0x04, 0x04, 0, 0, 0, 0],
            [0x07, 0x10, 0x05, 0x05, 0, 0, 0, 0],
            [0x07, 0x10, 0x06, 0x0C, 0, 0, 0, 0],
            [0x07, 0x10, 0x08, 0x0B, 0, 0, 0, 0],
            [0x07, 0x09, 0x00, 0x38, 0x0F, 0, 0, 0],
            [0x07, 0x09, 0x00, 0x49, 0x0F, 0, 0, 0],
            [0x07, 0x09, 0x00, 0x6A, 0x0F, 0, 0, 0],
            [0x07, 0x09, 0x00, 0xCB, 0x0F, 0, 0, 0],
        ])
    }

    @Test func aSteadyColourIsSentAsItsSlotsThenTheModePacket() async throws {
        let mouse = FakeT20()
        let settings = T20Settings(lighting: T20Lighting(mode: .steady, color: T20Color(red: 255, green: 0, blue: 0)))

        try await T20Writer(transport: mouse, pause: { _ in }).writeLighting(settings.lighting)

        #expect(mouse.packets.count == 7)
        #expect(mouse.packets.first == [0x07, 0x14, 0x0F, 0x0F, 0, 0, 0, 0])
        #expect(mouse.packets.last == [0x07, 0x13, 0xFF, 0xA0, 0x0B, 0x08, 0x00, 0x00])
    }

    @Test func theMomentaryRefusalIsRetriedAfterAPause() async throws {
        let mouse = FakeT20()
        mouse.refuseOnceAfter(0)
        var pauses: [Duration] = []

        try await T20Writer(transport: mouse, pause: { pauses.append($0) }).write(T20Settings())

        #expect(mouse.packets.count == 14)
        #expect(pauses.contains(.milliseconds(400)))
    }

    @Test func anotherErrorIsNotRetried() async {
        let mouse = FakeT20()
        mouse.failAfter(1, with: MouseAccessError.notConnected)

        await #expect(throws: MouseAccessError.notConnected) {
            try await T20Writer(transport: mouse, pause: { _ in }).write(T20Settings())
        }
        #expect(mouse.packets.count == 1)
    }

    @Test func onlyTheMomentaryRefusalCountsAsWorthRetrying() {
        #expect(T20Writer.isMomentaryRefusal(MouseAccessError.reportRejected(IOReturn(bitPattern: 0xE000_02E2))))
        #expect(T20Writer.isMomentaryRefusal(MouseAccessError.accessRefused(IOReturn(bitPattern: 0xE000_02E2))))
        #expect(!T20Writer.isMomentaryRefusal(MouseAccessError.notConnected))
        #expect(!T20Writer.isMomentaryRefusal(MouseAccessError.reportRejected(0)))
    }
}

@Suite struct T20StoreTests {
    @Test func theSavedSettingsComeBackAsTheyWere() throws {
        let folder = URL.temporaryDirectory.appending(path: "t20-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = T20Store(fileURL: folder.appending(path: "t20.json"))
        var settings = T20Settings()
        settings.dpi = T20DPISettings(stages: [400, 900, 1600, 3000], enabled: [true, false, true, true], activeStage: 2)
        settings.lighting = T20Lighting(mode: .steady, color: T20Color(red: 0, green: 0, blue: 255), brightness: 3)
        settings.buttons[.sideBack] = .copy
        settings.scroll = .volume
        settings.fireRate = 20

        try store.save(settings)

        #expect(store.load() == settings)
    }

    @Test func aMissingFileIsNotAnError() {
        let store = T20Store(fileURL: URL.temporaryDirectory.appending(path: "t20-missing-\(UUID().uuidString).json"))
        #expect(store.load() == nil)
    }
}

/// Records the packets and can refuse or fail one of them, the way the interface does while it is busy.
@MainActor
private final class FakeT20: ReportTransport {
    private(set) var packets: [[UInt8]] = []
    private var refusal: (index: Int, error: any Error)?

    func refuseOnceAfter(_ packets: Int) {
        refusal = (packets, MouseAccessError.reportRejected(IOReturn(bitPattern: 0xE000_02E2)))
    }

    func failAfter(_ packets: Int, with error: any Error) {
        refusal = (packets, error)
    }

    func sendFeatureReport(_ bytes: [UInt8]) throws {
        if let refusal, packets.count == refusal.index {
            self.refusal = nil
            throw refusal.error
        }
        packets.append(bytes)
    }

    func sendOutputReport(_ bytes: [UInt8]) throws {
        Issue.record("The T-20 takes no output reports")
    }

    func readFeatureReport() throws -> [UInt8] {
        Issue.record("Nothing reads the T-20's report in these tests")
        return []
    }
}
