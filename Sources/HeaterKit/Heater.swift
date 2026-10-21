import Foundation

public struct HeaterMode: Hashable, Identifiable, Sendable {
    public let value: Int
    public let name: String
    public var id: Int { value }
}

public struct HeaterCapabilities: Equatable, Sendable {
    public let model: String
    public let targetRange: ClosedRange<Double>?
    public let targetStep: Double
    public let modes: [HeaterMode]
    public let hasTemperatureSensor: Bool
    public let hasOscillation: Bool
    public let hasCountdown: Bool
}

public struct HeaterState: Equatable, Sendable {
    public var isOn: Bool
    public var targetTemperature: Double?
    public var currentTemperature: Double?
    public var mode: Int?
    public var oscillating: Bool?
}

public enum HeaterError: LocalizedError {
    case invalidToken
    case timeout
    case unsupportedModel(String)
    case device(code: Int)
    case specUnavailable
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .invalidToken: "Invalid token (expected 32 hex characters)."
        case .timeout: "No response from the heater (timeout)."
        case .unsupportedModel(let model): "Unsupported model: \(model)."
        case .device(let code): "Heater error (code \(code))."
        case .specUnavailable: "MIoT spec unavailable."
        case .invalidResponse: "Invalid response from the heater."
        }
    }
}

public actor Heater {
    private struct Info: Decodable, Sendable { let model: String }

    private let client: MiIO
    private var mapping: MiotMapping?

    public init(ip: String, token: String) throws {
        guard token.count == 32, let key = Data(hex: token) else { throw HeaterError.invalidToken }
        client = MiIO(host: ip, token: key)
    }

    public func connect() async throws -> HeaterCapabilities {
        let info = try await client.call("miIO.info", as: Info.self)
        let m = try await MiotSpec.load(model: info.model)
        mapping = m
        return m.capabilities
    }

    public func state() async throws -> HeaterState {
        let m = try await resolved()
        let props = [m.power, m.target, m.temperature, m.mode, m.oscillation].compactMap { $0 }
        let results = try await client.call(
            "get_properties",
            params: props.map { PropRequest(siid: $0.siid, piid: $0.piid) },
            as: [PropResult].self
        )
        func value(_ p: MiotProp?) -> PropValue? {
            guard let p else { return nil }
            return results.first { $0.siid == p.siid && $0.piid == p.piid && $0.code == 0 }?.value
        }
        guard let isOn = value(m.power)?.bool else {
            let code = results.first { $0.siid == m.power.siid && $0.piid == m.power.piid }?.code
            throw code.map { HeaterError.device(code: $0) } ?? HeaterError.invalidResponse
        }
        return HeaterState(
            isOn: isOn,
            targetTemperature: value(m.target)?.double,
            currentTemperature: value(m.temperature)?.double,
            mode: value(m.mode)?.double.map { Int($0) },
            oscillating: value(m.oscillation)?.bool
        )
    }

    public func setPower(_ on: Bool) async throws {
        let m = try await resolved()
        guard let toggle = m.powerToggle else { return try await set(m.power, .bool(on)) }
        // Some firmwares (e.g. leshow.heater.nfj3lx) ack set_properties on "on" but ignore it;
        // the heater's toggle action works, so flip only when the current state differs.
        let current = try await client.call(
            "get_properties", params: [PropRequest(siid: m.power.siid, piid: m.power.piid)], as: [PropResult].self
        ).first?.value?.bool
        if current == on { return }
        let result = try await client.call(
            "action", params: ActionRequest(siid: toggle.siid, aiid: toggle.aiid), as: ActionResult.self
        )
        if result.code != 0 { throw HeaterError.device(code: result.code) }
    }

    /// Clamps to the supported range and rounds to the step.
    public func setTargetTemperature(_ value: Double) async throws {
        let m = try await resolved()
        guard let prop = m.target, let range = m.capabilities.targetRange else {
            throw HeaterError.unsupportedModel(m.capabilities.model)
        }
        let step = m.capabilities.targetStep
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        let rounded = ((clamped - range.lowerBound) / step).rounded() * step + range.lowerBound
        try await set(prop, .number(min(rounded, range.upperBound)))
    }

    public func setMode(_ value: Int) async throws {
        let m = try await resolved()
        guard let prop = m.mode else { throw HeaterError.unsupportedModel(m.capabilities.model) }
        try await set(prop, .number(Double(value)))
    }

    public func setOscillation(_ on: Bool) async throws {
        let m = try await resolved()
        guard let prop = m.oscillation else { throw HeaterError.unsupportedModel(m.capabilities.model) }
        try await set(prop, .bool(on))
    }

    /// Auto-off timer in minutes (0 cancels), clamped to the supported range.
    public func setCountdown(minutes: Int) async throws {
        let m = try await resolved()
        guard let prop = m.countdown else { throw HeaterError.unsupportedModel(m.capabilities.model) }
        let range = m.countdownRange ?? 0...Int.max
        try await set(prop, .number(Double(min(max(minutes, range.lowerBound), range.upperBound))))
    }

    private func resolved() async throws -> MiotMapping {
        if let mapping { return mapping }
        _ = try await connect()
        return mapping!
    }

    private func set(_ prop: MiotProp, _ value: PropValue) async throws {
        let results = try await client.call(
            "set_properties",
            params: [PropRequest(siid: prop.siid, piid: prop.piid, value: value)],
            as: [PropResult].self
        )
        guard let result = results.first else { throw HeaterError.invalidResponse }
        if result.code != 0 { throw HeaterError.device(code: result.code) }
    }
}
