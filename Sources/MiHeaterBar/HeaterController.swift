import Combine
import Foundation
import HeaterKit

/// Formats a temperature without trailing ".0" (21 -> "21", 21.4 -> "21.4").
func formatTemp(_ value: Double) -> String {
    String(format: "%g", value)
}

enum AutoStatus: Equatable {
    case off, heating(HeatLevel), paused(resumeIn: TimeInterval?), noSensor
}

struct WeekSummary: Equatable {
    var hours: Double
    var kWh: Double
    var cost: Double
}

@MainActor
final class HeaterController: ObservableObject {
    @Published private(set) var capabilities: HeaterCapabilities?
    @Published private(set) var state: HeaterState?
    @Published var errorMessage: String?
    @Published var autoEnabled: Bool {
        didSet { UserDefaults.standard.set(autoEnabled, forKey: "autoEnabled") }
    }
    @Published private(set) var autoStatus = AutoStatus.off
    @Published private(set) var weekSummary: WeekSummary?
    @Published var autoTarget: Double {
        didSet {
            UserDefaults.standard.set(autoTarget, forKey: "autoTarget")
            updateAutoStatus()
        }
    }
    @Published var pricePerKWh: Double {
        didSet {
            UserDefaults.standard.set(pricePerKWh, forKey: "price")
            if let s = weekSummary { weekSummary?.cost = s.kWh * pricePerKWh }
        }
    }

    private var heater: Heater?
    private var pausedSince: Date?
    private var pauseReadings: [(Date, Double)] = []
    private var heatLevel = HeatLevel.gentle
    private var lastCountdown: Date?
    private var lastSummary = Date.distantPast

    init() {
        let defaults = UserDefaults.standard
        autoEnabled = defaults.bool(forKey: "autoEnabled")
        autoTarget = defaults.object(forKey: "autoTarget") as? Double ?? 20
        pricePerKWh = defaults.object(forKey: "price") as? Double ?? 0.14
        Task {
            while true {
                await tick()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func reconnect() async {
        heater = nil
        let ip = UserDefaults.standard.string(forKey: "ip") ?? ""
        let token = TokenStore.token() ?? ""
        guard !ip.isEmpty, !token.isEmpty else {
            errorMessage = "Set the IP and token"
            return
        }
        do {
            let h = try Heater(ip: ip, token: token)
            capabilities = try await h.connect()
            heater = h
            await command("poll", source: "poll") { _ in }
        } catch {
            errorMessage = error.localizedDescription
            log("connect", source: "error", error: error.localizedDescription)
        }
    }

    func togglePower() async {
        await disableAuto()
        let on = !(state?.isOn ?? false)
        await command(on ? "power_on" : "power_off", source: "manual") { try await $0.setPower(on) }
    }

    func setTarget(_ value: Double) async {
        await disableAuto()
        await command("target:\(formatTemp(value))", source: "manual") { try await $0.setTargetTemperature(value) }
    }

    func setMode(_ value: Int) async {
        await disableAuto()
        await command("mode:\(modeName(value) ?? String(value))", source: "manual") { try await $0.setMode(value) }
    }

    /// Doesn't touch the auto: oscillation is independent of heating.
    func toggleOscillation() async {
        let on = !(state?.oscillating ?? false)
        await command(on ? "osc_on" : "osc_off", source: "manual") { try await $0.setOscillation(on) }
    }

    func setAuto(_ on: Bool) async {
        guard on else { return await disableAuto() }
        autoEnabled = true
        resetPause()
        log("auto_on", source: "manual")
        await applyAuto()
    }

    private func disableAuto() async {
        guard autoEnabled else { return }
        autoEnabled = false
        resetPause()
        updateAutoStatus()
        log("auto_off", source: "manual")
        if capabilities?.hasCountdown == true {
            await command("countdown:0", source: "manual") { try await $0.setCountdown(minutes: 0) }
        }
    }

    private func tick() async {
        if Date().timeIntervalSince(lastSummary) >= 600 { await refreshSummary() }
        guard heater != nil else {
            await reconnect()
            return
        }
        if await command("poll", source: "poll", { _ in }), autoEnabled { await applyAuto() }
    }

    private func applyAuto() async {
        guard let state else { return }
        let now = Date()
        if !state.isOn, let t = state.currentTemperature { pauseReadings.append((now, t)) }
        let action = SmartAuto.decide(current: state.currentTemperature, target: autoTarget,
                                      isOn: state.isOn, pausedSince: pausedSince, now: now)
        switch action {
        case .heat(let level):
            heatLevel = level
            if !state.isOn {
                guard await command("power_on", source: "auto", { try await $0.setPower(true) }) else { break }
                resetPause()
            }
            let name = level == .strong ? "Heat" : "Warm"
            if let mode = capabilities?.modes.first(where: { $0.name == name }), state.mode != mode.value {
                await command("mode:\(name)", source: "auto") { try await $0.setMode(mode.value) }
            }
        case .pause:
            if await command("power_off", source: "auto", { try await $0.setPower(false) }) {
                pausedSince = now
                pauseReadings = state.currentTemperature.map { [(now, $0)] } ?? []
            }
        case .keep:
            break
        }
        // Fail-safe: if the app stops refreshing this timer, the heater switches itself off within 60 min.
        if self.state?.isOn == true, capabilities?.hasCountdown == true,
           lastCountdown.map({ now.timeIntervalSince($0) >= 15 * 60 }) ?? true,
           await command("countdown:60", source: "auto", { try await $0.setCountdown(minutes: 60) }) {
            lastCountdown = now
        }
        updateAutoStatus()
    }

    private func resetPause() {
        pausedSince = nil
        pauseReadings = []
        lastCountdown = nil
    }

    private func updateAutoStatus() {
        guard autoEnabled else {
            autoStatus = .off
            return
        }
        guard let state, state.currentTemperature != nil else {
            autoStatus = .noSensor
            return
        }
        autoStatus = state.isOn
            ? .heating(heatLevel)
            : .paused(resumeIn: SmartAuto.estimatedResume(readings: pauseReadings, target: autoTarget, now: Date()))
    }

    private func refreshSummary() async {
        lastSummary = Date()
        let r = await Task.detached { EnergyEstimate.summarize(EventLog.samples(since: Date() - 7 * 86400)) }.value
        weekSummary = WeekSummary(hours: r.hours, kWh: r.kWh, cost: r.kWh * pricePerKWh)
    }

    private func modeName(_ value: Int) -> String? {
        capabilities?.modes.first { $0.value == value }?.name
    }

    private func log(_ action: String, source: String, error: String = "") {
        EventLog.append(state: state, modeName: state?.mode.flatMap(modeName), auto: autoEnabled,
                        autoTarget: autoTarget, action: action, source: source, error: error)
    }

    /// Runs a device command, re-reads the state and logs it. Errors go to errorMessage and the log.
    @discardableResult
    private func command(_ action: String, source: String, _ work: (Heater) async throws -> Void) async -> Bool {
        guard let heater else {
            errorMessage = "Not connected"
            return false
        }
        do {
            try await work(heater)
            state = try await heater.state()
            errorMessage = nil
            log(action, source: source)
            return true
        } catch {
            errorMessage = error.localizedDescription
            log(action, source: "error", error: error.localizedDescription)
            return false
        }
    }
}
