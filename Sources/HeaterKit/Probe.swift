import Foundation

public enum Probe {
    static let usage = "usage: MiHeaterBar <ip> <token> [--power on|off] [--target N] [--mode N] [--osc on|off] [--countdown N]\n"

    /// args: <ip> <token> [--power on|off] [--target N] [--mode N] [--osc on|off] [--countdown N]
    /// Applies the requested sets, then prints capabilities and state as JSON.
    /// Exit 0 ok, 1 error (stderr), 2 usage.
    public static func run(_ args: [String]) async -> Int32 {
        guard args.count >= 2 else { return fail(usage, 2) }
        var power: Bool?
        var target: Double?
        var mode: Int?
        var osc: Bool?
        var countdown: Int?
        var rest = args.dropFirst(2)
        while let flag = rest.popFirst() {
            guard let value = rest.popFirst() else { return fail(usage, 2) }
            switch (flag, value) {
            case ("--power", "on"): power = true
            case ("--power", "off"): power = false
            case ("--target", _) where Double(value) != nil: target = Double(value)
            case ("--mode", _) where Int(value) != nil: mode = Int(value)
            case ("--osc", "on"): osc = true
            case ("--osc", "off"): osc = false
            case ("--countdown", _) where Int(value) != nil: countdown = Int(value)
            default: return fail(usage, 2)
            }
        }

        do {
            let heater = try Heater(ip: args[0], token: args[1])
            let caps = try await heater.connect()
            if let power { try await heater.setPower(power) }
            if let target { try await heater.setTargetTemperature(target) }
            if let mode { try await heater.setMode(mode) }
            if let osc { try await heater.setOscillation(osc) }
            if let countdown { try await heater.setCountdown(minutes: countdown) }
            let state = try await heater.state()

            let json: [String: Any] = [
                "model": caps.model,
                "targetRange": caps.targetRange.map { [$0.lowerBound, $0.upperBound] } ?? NSNull(),
                "targetStep": caps.targetStep,
                "modes": caps.modes.map { ["value": $0.value, "name": $0.name] },
                "hasTemperatureSensor": caps.hasTemperatureSensor,
                "hasOscillation": caps.hasOscillation,
                "hasCountdown": caps.hasCountdown,
                "state": [
                    "isOn": state.isOn,
                    "targetTemperature": state.targetTemperature ?? NSNull(),
                    "currentTemperature": state.currentTemperature ?? NSNull(),
                    "mode": state.mode ?? NSNull(),
                    "oscillating": state.oscillating ?? NSNull(),
                ] as [String: Any],
            ]
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
            FileHandle.standardOutput.write(data + Data("\n".utf8))
            return 0
        } catch {
            return fail("error: \(error.localizedDescription)\n", 1)
        }
    }

    private static func fail(_ message: String, _ code: Int32) -> Int32 {
        FileHandle.standardError.write(Data(message.utf8))
        return code
    }
}
