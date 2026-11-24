import Foundation
import ZelotesKit

/// Developer tool: runs one experiment against the mouse and prints every packet in both directions.
@main
@MainActor
struct Probe {
    enum Experiment: String, CaseIterable {
        /// Lists every HID interface macOS can see, with its IDs, usage page and report sizes. Sends nothing.
        case devices
        /// Reads the mouse's status report twice. Sends no command.
        case status
        /// Makes the profile the active one without changing what it holds.
        case select
        /// Writes again the button table the app last wrote to the profile.
        case table
        /// Writes the factory DPI settings to the profile. The same table carries the lighting,
        /// so this also sends that profile's factory lighting.
        case dpi
        /// Prints how often the mouse reports and how far it moves in each stroke, until Ctrl-C. Sends no command.
        case measure
        /// Reads one feature report again and again and prints only the bytes that changed. Sends nothing.
        case feature
        /// Prints each input report that differs from the last one on its interface. Sends nothing.
        case listen
        /// Reads the T-20's status report once. Sends nothing.
        case t20Status = "t20-status"
        /// Writes the T-20's default DPI stages and reads the status after every command.
        case t20DPI = "t20-dpi"
        /// Writes one T-20 lighting mode; `--light` and `--colour` choose it.
        case t20Light = "t20-light"

        /// The T-20 experiments target its own IDs unless the command line says otherwise.
        var isT20: Bool {
            switch self {
            case .t20Status, .t20DPI, .t20Light: true
            default: false
            }
        }
    }

    static func main() async {
        guard let options = Options(arguments: Array(CommandLine.arguments.dropFirst())) else {
            print(Options.usage)
            exit(2)
        }
        if options.experiment == .devices {
            DeviceList.run(filter: options.filter)
            return
        }

        if let mode = options.reconMode {
            do {
                try await ReportRecon.run(mode, vendorID: options.vendorID, productID: options.productID)
            } catch {
                print("failed: \(error.localizedDescription)")
                exit(1)
            }
            return
        }

        do {
            let connection = MouseConnection(
                vendorID: options.vendorID,
                productID: options.productID,
                configurationUsagePage: options.usagePage,
                configurationUsage: options.usage,
                featureReportID: options.configReportID
            )
            try connection.start()
            let trace = TracingChannel(try await channel(of: connection))
            try await run(options.experiment, options, trace)
            try await Task.sleep(for: lingerForLateReplies)
        } catch {
            print("failed: \(error.localizedDescription)")
            exit(1)
        }
    }

    /// The command line. The ID options default to the C-18's; they exist so a mouse the app does not know yet
    /// can be tried before its numbers are written into the code.
    private struct Options {
        let experiment: Experiment
        var profile: MouseProfile = .first
        var vendorID: Int = DeviceIdentity.vendorID
        var productID: Int = DeviceIdentity.productID
        var usagePage: Int = DeviceIdentity.configurationUsagePage
        var filter: String?
        var featureID: CFIndex = 7
        var reportStartsWithID = false
        var usage: Int?
        var configReportID: CFIndex = 0
        var light: T20LightingMode = .steady
        var colour = T20Color(red: 0xFF, green: 0, blue: 0)
        var brightness: UInt8 = 7
        var modeCode: UInt8?
        var extendedCode: UInt8?
        var speed: UInt8 = 0

        var reconMode: ReportRecon.Mode? {
            switch experiment {
            case .feature: .feature(id: featureID)
            case .listen: .input
            default: nil
            }
        }

        static let usage = """
            usage: ZelotesProbe <\(Experiment.allCases.map(\.rawValue).joined(separator: "|"))> [options]

            options:
              --profile 1|2         profile to work on; default 1
              --vendor 0x12c9       USB vendor ID of the device to open
              --product 0x2003      USB product ID of the device to open
              --usage-page 0xff00   usage page of its configuration interface
              --feature-id 7        feature report to read in the feature experiment
              --report-id           measure: the movement report starts with its report ID
              --filter text         devices: only the interfaces whose product or maker contains text
              --usage 2             usage of the configuration interface, when its page has several
              --config-report 7     report ID of the configuration feature report; the C-18 uses 0
              --light MODE          t20-light: off, steady, breathing, rainbow, spectrum; default steady
              --colour rrggbb      t20-light: colour as hex; default ff0000.
              --brightness 0..7    t20-light: default 7, the dimmest.
              --mode-code 0x16     t20-light: send only 07 13 7f <code>, without the colour slots.
              --extended-code 0x0a t20-light: send 07 13 ff <mode<<4|speed> 0b <0f-brightness> 00 after the slots.
              --speed 0..5         t20-light: speed nibble for --extended-code; 6 and above freezes the effect.
                The T-20 experiments default to its own IDs: 30fa:1701, usage page 1 usage 2, report 7.
            """

        init?(arguments: [String]) {
            var arguments = arguments[...]
            var experiment: Experiment?
            var vendorWasSet = false
            var productWasSet = false
            var usagePageWasSet = false
            var usageWasSet = false
            var configReportWasSet = false
            while let argument = arguments.popFirst() {
                switch argument {
                case "--profile":
                    guard let value = arguments.popFirst().flatMap(UInt8.init),
                          let profile = MouseProfile(rawValue: value) else { return nil }
                    self.profile = profile
                case "--vendor":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    vendorID = value
                    vendorWasSet = true
                case "--product":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    productID = value
                    productWasSet = true
                case "--usage-page":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    usagePage = value
                    usagePageWasSet = true
                case "--filter":
                    guard let value = arguments.popFirst() else { return nil }
                    filter = value
                case "--feature-id":
                    guard let value = arguments.popFirst().flatMap(Int.init) else { return nil }
                    featureID = CFIndex(value)
                case "--report-id":
                    reportStartsWithID = true
                case "--usage":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    usage = value
                    usageWasSet = true
                case "--config-report":
                    guard let value = arguments.popFirst().flatMap(Int.init) else { return nil }
                    configReportID = CFIndex(value)
                    configReportWasSet = true
                case "--light":
                    guard let value = arguments.popFirst(),
                          let mode = Self.lightingMode(value) else { return nil }
                    light = mode
                case "--colour":
                    guard let value = arguments.popFirst(), let color = T20Color(hex: value) else { return nil }
                    colour = color
                case "--brightness":
                    guard let value = arguments.popFirst().flatMap(UInt8.init), value <= 7 else { return nil }
                    brightness = value
                case "--mode-code":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    modeCode = UInt8(truncatingIfNeeded: value)
                case "--extended-code":
                    guard let value = arguments.popFirst().flatMap(Self.number) else { return nil }
                    extendedCode = UInt8(truncatingIfNeeded: value)
                case "--speed":
                    guard let value = arguments.popFirst().flatMap(UInt8.init), value <= 5 else { return nil }
                    speed = value
                default:
                    if let profile = UInt8(argument).flatMap(MouseProfile.init(rawValue:)) {
                        // A bare number is the profile, as it was before the options existed.
                        self.profile = profile
                    } else if experiment == nil, let value = Experiment(rawValue: argument) {
                        experiment = value
                    } else {
                        return nil
                    }
                }
            }
            guard let experiment else { return nil }
            self.experiment = experiment

            if experiment.isT20 {
                if !vendorWasSet { vendorID = T20Identity.vendorID }
                if !productWasSet { productID = T20Identity.productID }
                if !usagePageWasSet { usagePage = T20Identity.configurationUsagePage }
                if !usageWasSet { usage = T20Identity.configurationUsage }
                if !configReportWasSet { configReportID = T20Command.reportID }
            }
        }

        private static func lightingMode(_ text: String) -> T20LightingMode? {
            text == "rainbow" ? .rainbowBreathing : T20LightingMode(rawValue: text)
        }

        private static func number(_ text: String) -> Int? {
            if text.hasPrefix("0x") || text.hasPrefix("0X") {
                return Int(text.dropFirst(2), radix: 16)
            }
            return Int(text)
        }
    }

    private static let lingerForLateReplies = Duration.milliseconds(500)

    private static func run(_ experiment: Experiment, _ options: Options, _ trace: TracingChannel) async throws {
        trace.readStatus()
        let writer = ProfileWriter(transport: trace)
        let profile = options.profile
        switch experiment {
        case .devices, .feature, .listen:
            break
        case .status:
            try await Task.sleep(for: .milliseconds(100))
            trace.readStatus()
        case .select:
            try await writer.select(profile)
        case .table:
            let library = MappingStore(fileURL: MappingStore.standardFileURL).load()
            guard let written = library?.written(to: profile) else {
                print("The app has not written to profile \(profile.rawValue) yet; move a preset into it from the app first.")
                return
            }
            try await writer.write(ProfileUpdate(buttons: written.table), to: profile)
        case .dpi:
            try await writer.write(ProfileUpdate(dpi: .factoryDefault), to: profile)
        case .t20Status:
            trace.readStatus()
        case .t20DPI:
            try await T20Writer(transport: trace).writeDPI(.factoryDefault)
            trace.readStatus()
        case .t20Light:
            if let code = options.extendedCode {
                let writer = T20Writer(transport: trace)
                try await writer.writeColourSlots(options.colour)
                try await writer.sendExtended(mode: code, speed: options.speed, brightness: options.brightness)
            } else if let code = options.modeCode {
                try await T20Writer(transport: trace).sendRawMode(code)
            } else {
                let lighting = T20Lighting(mode: options.light, color: options.colour, brightness: options.brightness)
                try await T20Writer(transport: trace).writeLighting(lighting)
            }
            trace.readStatus()
        case .measure:
            try await MovementMeter(
                vendorID: options.vendorID,
                productID: options.productID,
                reportStartsWithID: options.reportStartsWithID
            ).run()
        }
    }

    private static func channel(of connection: MouseConnection) async throws -> ConfigurationChannel {
        for _ in 0..<40 {
            if let channel = connection.configurationChannel {
                return channel
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MouseAccessError.notConnected
    }
}

@MainActor
private final class TracingChannel: ReportTransport {
    private let channel: ConfigurationChannel
    private let start = ContinuousClock.now

    init(_ channel: ConfigurationChannel) {
        self.channel = channel
        channel.onInputReport = { [weak self] bytes in
            self?.log("<- input  ", bytes)
        }
    }

    func sendFeatureReport(_ bytes: [UInt8]) throws {
        log("-> feature", bytes)
        try channel.sendFeatureReport(bytes)
    }

    func sendOutputReport(_ bytes: [UInt8]) throws {
        log("-> output ", bytes)
        try channel.sendOutputReport(bytes)
    }

    func readFeatureReport() throws -> [UInt8] {
        let report = try channel.readFeatureReport()
        log("== status ", report)
        return report
    }

    func readStatus() {
        do {
            _ = try readFeatureReport()
        } catch {
            print("== status read failed: \(error.localizedDescription)")
        }
    }

    private func log(_ label: String, _ bytes: [UInt8]) {
        let elapsed = start.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        let hex = bytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print(String(format: "%8.1f ms  %@  %@", milliseconds, label, hex))
    }
}
