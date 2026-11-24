import AppKit
import SwiftUI
import ZelotesKit

/// The T-20 tab. Unlike the C-18, the T-20 has no profiles and stores nothing, so there is one set of settings
/// and it goes to the mouse as soon as it changes.
struct T20View: View {
    @Bindable var model: T20Model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 30)
                .padding(.top, 18)
            Form {
                dpiSection
                lightingSection
                buttonsSection
                wheelSection
                keepingSection
            }
            .formStyle(.grouped)
        }
        .frame(minWidth: 780, minHeight: 600)
        .toolbar {
            ToolbarSpacer(.flexible)
            ToolbarItem {
                Button("Update Mouse") { model.updateMouse() }
                    .disabled(!model.isMouseConnected || model.isBusy)
                    .help("Send these settings to the T-20 again")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Zelotes T-20")
                .font(.largeTitle.weight(.bold))
            status
                .font(.callout)
                .animation(.snappy, value: model.writeState)
                .animation(.snappy, value: model.isOnMouse)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var status: some View {
        if let accessError = model.accessError {
            accessNotice(accessError)
        } else {
            writeStatus
        }
    }

    private func accessNotice(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Label("macOS does not let ZelotesMac open the T-20 yet.", systemImage: "lock.fill")
                    .foregroundStyle(.orange)
                Button("Open Input Monitoring") { Self.openInputMonitoringSettings() }
                    .buttonStyle(.link)
            }
            Text("Turn ZelotesMac on in System Settings › Privacy & Security › Input Monitoring, then reopen the "
                + "app. macOS asks because the T-20 is a mouse. (\(reason))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var writeStatus: some View {
        switch model.writeState {
        case .failed(let reason):
            HStack(spacing: 10) {
                Label(reason, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                if model.isMouseConnected {
                    Button("Try Again") { model.updateMouse() }
                        .buttonStyle(.link)
                }
            }
        case .writing:
            Label("Updating the T-20…", systemImage: "arrow.down.circle")
                .foregroundStyle(.secondary)
        case .idle:
            idleStatus
        }
    }

    @ViewBuilder private var idleStatus: some View {
        if !model.isMouseConnected {
            Label("Connect the T-20 to send these settings.", systemImage: "cable.connector")
                .foregroundStyle(.secondary)
        } else if model.isHeldWithoutLeftClick {
            Label("Not sent: no button is set to Left Click", systemImage: "hand.raised.fill")
                .foregroundStyle(.orange)
        } else if model.isOnMouse {
            Label("On the T-20", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Label("Sending…", systemImage: "arrow.triangle.2.circlepath")
                .foregroundStyle(.secondary)
        }
    }

    private var dpiSection: some View {
        Section {
            ForEach(Array(0..<T20DPISettings.stageCount), id: \.self) { stage in
                LabeledContent {
                    HStack(spacing: 12) {
                        Picker("DPI", selection: dpiValue(stage)) {
                            ForEach(T20DPISettings.dpiChoices, id: \.self) { value in
                                Text(verbatim: "\(value) DPI").tag(value)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                        Toggle("In the cycle", isOn: isStageEnabled(stage))
                            .labelsHidden()
                            .toggleStyle(.checkbox)
                            .help("Leave this stage in the cycle the DPI button goes through")
                    }
                } label: {
                    Button {
                        model.change { $0.dpi.activeStage = stage }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Image(systemName: isStageActive(stage) ? "\(stage + 1).circle.fill" : "\(stage + 1).circle")
                                .foregroundStyle(isStageActive(stage) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            Text(verbatim: "Stage \(stage + 1)")
                            if isStageActive(stage) {
                                ActivePill()
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(isStageActive(stage) ? "" : "Make this the stage the mouse starts on")
                }
            }
        } header: {
            TitleWithInfo(title: "DPI Stages", info: Self.dpiInfo)
        } footer: {
            Text("The DPI button on the mouse changes the stage without telling the Mac, so Active shows the stage "
                + "chosen here last.")
        }
    }

    private var lightingSection: some View {
        Section {
            Picker("Effect", selection: lightingMode) {
                ForEach(T20LightingMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if takesColour {
                LabeledContent("Color") {
                    T20ColorSwatches(color: model.settings.lighting.color) { color in
                        model.change { $0.lighting.color = color }
                    }
                }
            }
            if takesSpeed {
                Picker("Speed", selection: lightingSpeed) {
                    ForEach(0...5, id: \.self) { speed in
                        Text(verbatim: "Level \(speed + 1)").tag(UInt8(speed))
                    }
                }
                .pickerStyle(.menu)
            }
            if takesBrightness {
                Picker("Brightness", selection: lightingBrightness) {
                    ForEach(UInt8(0)...UInt8(7), id: \.self) { level in
                        Text(verbatim: "\(level)").tag(level)
                    }
                }
                .pickerStyle(.menu)
            }
        } header: {
            TitleWithInfo(title: "Lighting", info: Self.lightingInfo)
        } footer: {
            Text("The mouse has a red and a blue LED, so only those two colours light up; the vendor software "
                + "offers the rest of the palette that the mouse cannot show.")
        }
    }

    private var buttonsSection: some View {
        Section {
            ForEach(T20Button.onMouse, id: \.self) { button in
                LabeledContent(button.title) {
                    Picker("Action", selection: binding(button)) {
                        ForEach(T20ButtonAction.assignable, id: \.self) { action in
                            Text(action.title).tag(T20Binding.action(action))
                        }
                        Section("Mac Shortcuts") {
                            ForEach(Self.shortcutCommands, id: \.self) { command in
                                Text(command.title(on: .macOS)).tag(T20Binding.shortcut(command))
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
            }
            if !model.settings.hasLeftClick {
                Label(
                    "No button is set to Left Click, so the settings are kept on this Mac and not sent.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
            if let problem = model.shortcutProblem {
                shortcutNotice(problem)
            }
        } header: {
            TitleWithInfo(title: "Buttons", info: Self.buttonsInfo)
        }
    }

    private func shortcutNotice(_ problem: String) -> some View {
        HStack(spacing: 10) {
            Label(problem, systemImage: "lock.fill")
                .foregroundStyle(.orange)
            Button("Open Accessibility Settings") { Self.openAccessibilitySettings() }
                .buttonStyle(.link)
        }
    }

    private var wheelSection: some View {
        Section {
            Picker("Wheel", selection: scroll) {
                ForEach(T20ScrollMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            LabeledContent("Auto-Fire interval") {
                Stepper(value: fireRate, in: 0...255) {
                    Text(verbatim: "\(model.settings.fireRate)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            TitleWithInfo(title: "Wheel and Auto-Fire", info: Self.wheelInfo)
        }
    }

    private var keepingSection: some View {
        Section {
            Text("The T-20 stores nothing: these settings are kept on this Mac and sent to the mouse again each "
                + "time it is plugged in, and whenever they change.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var takesColour: Bool {
        model.settings.lighting.mode != .off && model.settings.lighting.mode != .rainbowBreathing
    }

    private var takesSpeed: Bool {
        model.settings.lighting.mode != .off && model.settings.lighting.mode != .steady
    }

    private var takesBrightness: Bool {
        model.settings.lighting.mode != .off && model.settings.lighting.mode != .rainbowBreathing
    }

    private func isStageActive(_ stage: Int) -> Bool {
        model.settings.dpi.activeStage == stage
    }

    private func dpiValue(_ stage: Int) -> Binding<Int> {
        Binding(
            get: { model.settings.dpi.stages[stage] },
            set: { value in model.change { $0.dpi.stages[stage] = value } }
        )
    }

    private func isStageEnabled(_ stage: Int) -> Binding<Bool> {
        Binding(
            get: { model.settings.dpi.enabled[stage] },
            set: { value in model.change { $0.dpi.enabled[stage] = value } }
        )
    }

    private var lightingMode: Binding<T20LightingMode> {
        Binding(
            get: { model.settings.lighting.mode },
            set: { mode in model.change { $0.lighting.mode = mode } }
        )
    }

    private var lightingSpeed: Binding<UInt8> {
        Binding(
            get: { model.settings.lighting.speed },
            set: { speed in model.change { $0.lighting.speed = speed } }
        )
    }

    private var lightingBrightness: Binding<UInt8> {
        Binding(
            get: { model.settings.lighting.brightness },
            set: { level in model.change { $0.lighting.brightness = level } }
        )
    }

    /// One picker for both the things the mouse does itself and the shortcuts the Mac presses for it.
    private enum T20Binding: Hashable {
        case action(T20ButtonAction)
        case shortcut(WindowCommand)
    }

    /// The shortcuts the Mac can press, which are the ones macOS has a default key combination for.
    private static let shortcutCommands = WindowCommand.allCases.filter { $0.keyStroke(on: .macOS) != nil }

    private func binding(_ button: T20Button) -> Binding<T20Binding> {
        Binding(
            get: {
                if let shortcut = model.settings.shortcut(for: button) {
                    return .shortcut(shortcut)
                }
                return .action(model.settings.buttons[button] ?? .hostKey)
            },
            set: { value in
                model.change { settings in
                    switch value {
                    case .action(let action):
                        settings.setShortcut(nil, for: button)
                        settings.buttons[button] = action
                    case .shortcut(let command):
                        settings.setShortcut(command, for: button)
                    }
                }
            }
        )
    }

    private var scroll: Binding<T20ScrollMode> {
        Binding(
            get: { model.settings.scroll },
            set: { mode in model.change { $0.scroll = mode } }
        )
    }

    private var fireRate: Binding<UInt8> {
        Binding(
            get: { model.settings.fireRate },
            set: { rate in model.change { $0.fireRate = rate } }
        )
    }

    private static func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    private static let dpiInfo = "DPI is how sensitive the mouse is. The T-20 has four stages of 200 to 3000 DPI in "
        + "steps of 200. A stage left out of the cycle is skipped by the DPI button, which changes the stage on the "
        + "mouse without telling the Mac."

    private static let lightingInfo = "Steady keeps one colour on. Breathing, Spectrum and Rainbow breathe or move "
        + "through their colours. The mouse shows red and blue only, so a mix of the two looks blue or red."

    private static let buttonsInfo = "Each button either does something on the mouse itself, or is set to a Mac "
        + "Shortcut: the mouse then reports the press to this Mac, and ZelotesMac presses that shortcut, so the "
        + "shortcut has to be one macOS has a default for and needs Accessibility permission. The app lists the six "
        + "buttons the mouse has."

    private static let wheelInfo = "Volume makes the wheel change the volume and Reversed turns it around. Auto-Fire "
        + "repeats clicks while a button set to it is held."
}

/// The two colours the T-20's LEDs can show, drawn like the accent colours in System Settings.
private struct T20ColorSwatches: View {
    let color: T20Color
    let choose: (T20Color) -> Void

    private static let choices: [(name: String, color: T20Color, swatch: Color)] = [
        ("Red", T20Color(red: 255, green: 0, blue: 0), .red),
        ("Blue", T20Color(red: 0, green: 0, blue: 255), .blue),
    ]

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Self.choices, id: \.name) { choice in
                Button {
                    choose(choice.color)
                } label: {
                    Circle()
                        .fill(choice.swatch)
                        .overlay {
                            Circle().strokeBorder(.primary.opacity(0.15), lineWidth: 0.5)
                        }
                        .overlay {
                            if isSelected(choice.color) {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 6, height: 6)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .help(choice.name)
                .accessibilityLabel(choice.name)
                .accessibilityAddTraits(isSelected(choice.color) ? .isSelected : [])
            }
        }
    }

    private func isSelected(_ candidate: T20Color) -> Bool {
        candidate == color
    }
}
