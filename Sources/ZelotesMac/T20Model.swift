import Foundation
import IOKit.hid
import Observation
import OSLog
import ZelotesKit

/// The T-20 and the settings saved for it. The mouse keeps nothing, so the saved settings are sent again after
/// every change and after every plug-in.
@MainActor
@Observable
final class T20Model {
    enum WriteState: Equatable {
        case idle
        case writing
        case failed(String)
    }

    private(set) var settings: T20Settings
    private(set) var isMouseConnected = false
    /// Whether what the mouse has is what `settings` says.
    private(set) var isOnMouse = false
    private(set) var writeState = WriteState.idle
    /// True while the settings are held back, because sending them would leave no button clicking.
    private(set) var isHeldWithoutLeftClick = false
    /// Why macOS refused to open the T-20, when it did: it is a mouse, so macOS only lets an app open it with
    /// Input Monitoring.
    private(set) var accessError: String?

    @ObservationIgnored private let store: T20Store
    @ObservationIgnored private let connection: MouseConnection
    @ObservationIgnored private let log = Logger(subsystem: "local.zelotes-mac", category: "t20")
    @ObservationIgnored private var lastWork: Task<Void, Never>?
    @ObservationIgnored private var settleWork: Task<Void, Never>?

    /// A change waits for the clicking to stop before it is sent, so dragging a stepper does not write once a pixel.
    private static let settleDelay = Duration.milliseconds(700)

    init(store: T20Store = T20Store(fileURL: T20Store.standardFileURL)) {
        self.store = store
        settings = store.load() ?? T20Settings()
        connection = MouseConnection(
            vendorID: T20Identity.vendorID,
            productID: T20Identity.productID,
            configurationUsagePage: T20Identity.configurationUsagePage,
            configurationUsage: T20Identity.configurationUsage,
            featureReportID: T20Identity.featureReportID
        )
        connection.onChange = { [weak self] in self?.connectionChanged() }
        // Asking is what adds the app to System Settings › Privacy & Security › Input Monitoring and shows the
        // system's question on the first launch.
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        do {
            try connection.start()
        } catch {
            accessError = error.localizedDescription
            log.error("T-20: \(error.localizedDescription, privacy: .public)")
        }
    }

    var isBusy: Bool {
        writeState == .writing
    }

    /// Edits the settings, saves them and sends them once the user has finished changing them.
    func change(_ edit: (inout T20Settings) -> Void) {
        edit(&settings)
        persist()
        isOnMouse = false
        scheduleWrite()
    }

    /// Sends the settings now, as the Update Mouse button does.
    func updateMouse() {
        enqueueWrite()
    }

    /// Finishes the write in flight and sends what is still waiting, so quitting does not leave the mouse behind.
    func finishPendingWork() async {
        settleWork?.cancel()
        if !isOnMouse, isMouseConnected {
            enqueueWrite()
        }
        await lastWork?.value
    }

    private func scheduleWrite() {
        settleWork?.cancel()
        guard isMouseConnected else { return }
        settleWork = Task { [weak self] in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            self?.enqueueWrite()
        }
    }

    /// Runs the write once the writes asked for before it have finished, so they reach the mouse in order.
    private func enqueueWrite() {
        let previous = lastWork
        lastWork = Task { [weak self] in
            await previous?.value
            await self?.writeSettings()
        }
    }

    private func writeSettings() async {
        guard accessError == nil, settings.hasLeftClick else {
            isHeldWithoutLeftClick = accessError == nil
            isOnMouse = false
            return
        }
        isHeldWithoutLeftClick = false
        guard let channel = connection.configurationChannel else {
            isOnMouse = false
            return
        }
        writeState = .writing
        do {
            try await T20Writer(transport: channel).write(settings)
            writeState = .idle
            isOnMouse = true
            log.info("Updated the T-20")
        } catch {
            fail(error)
        }
    }

    private func connectionChanged() {
        isMouseConnected = connection.configurationChannel != nil
        guard isMouseConnected, accessError == nil else {
            settleWork?.cancel()
            isOnMouse = false
            if case .failed = writeState {
                writeState = .idle
            }
            log.info("T-20 disconnected")
            return
        }
        log.info("T-20 connected")
        enqueueWrite()
    }

    private func persist() {
        do {
            try store.save(settings)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: any Error) {
        writeState = .failed(error.localizedDescription)
        isOnMouse = false
        log.error("\(error.localizedDescription, privacy: .public)")
    }
}
