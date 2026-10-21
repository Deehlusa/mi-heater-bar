import Foundation

struct MiotProp: Equatable, Sendable {
    let siid: Int
    let piid: Int
}

struct MiotAction: Equatable, Sendable {
    let siid: Int
    let aiid: Int
}

// Where each heater feature lives in a model's MIoT spec.
struct MiotMapping: Equatable, Sendable {
    let power: MiotProp
    let powerToggle: MiotAction?
    let target: MiotProp?
    let temperature: MiotProp?
    let mode: MiotProp?
    let oscillation: MiotProp?
    let countdown: MiotProp?
    let countdownRange: ClosedRange<Int>?
    let capabilities: HeaterCapabilities
}

enum MiotSpec {
    private struct Spec: Decodable {
        struct Value: Decodable { let value: Int; let description: String }
        struct Property: Decodable {
            let iid: Int
            let type: String
            let valueRange: [Double]?
            let valueList: [Value]?
            enum CodingKeys: String, CodingKey {
                case iid, type
                case valueRange = "value-range"
                case valueList = "value-list"
            }
        }
        struct Action: Decodable { let iid: Int; let type: String }
        struct Service: Decodable {
            let iid: Int
            let type: String
            let properties: [Property]?
            let actions: [Action]?
        }
        let services: [Service]
    }

    private struct Instances: Decodable {
        struct Instance: Decodable { let model: String; let type: String; let version: Int; let status: String }
        let instances: [Instance]
    }

    /// 4th segment of a MIoT URN, e.g. "urn:miot-spec-v2:service:heater:..." -> "heater".
    static func name(_ urn: String) -> String {
        let parts = urn.split(separator: ":", omittingEmptySubsequences: false)
        return parts.count > 3 ? String(parts[3]) : ""
    }

    static func parse(_ data: Data, model: String) throws -> MiotMapping {
        guard let spec = try? JSONDecoder().decode(Spec.self, from: data) else { throw HeaterError.specUnavailable }

        func find(_ service: String, _ property: String) -> (MiotProp, Spec.Property)? {
            for s in spec.services where name(s.type) == service {
                for p in s.properties ?? [] where name(p.type) == property {
                    return (MiotProp(siid: s.iid, piid: p.iid), p)
                }
            }
            return nil
        }

        guard let power = find("heater", "on") else { throw HeaterError.unsupportedModel(model) }
        let target = find("heater", "target-temperature")
        let temperature = find("environment", "temperature") ?? find("heater", "temperature")
        let mode = find("heater", "mode") ?? find("heater", "heat-level")
        let oscillation = find("sway", "on") ?? find("swing", "on")
        let countdown = find("countdown", "countdown-time")
        let powerToggle = spec.services.first { name($0.type) == "heater" }
            .flatMap { s in s.actions?.first { name($0.type) == "toggle" }.map { MiotAction(siid: s.iid, aiid: $0.iid) } }

        var range: ClosedRange<Double>?
        var step = 1.0
        if let r = target?.1.valueRange, r.count >= 2, r[0] <= r[1] {
            range = r[0]...r[1]
            if r.count >= 3, r[2] > 0 { step = r[2] }
        }
        let modes = (mode?.1.valueList ?? []).map { HeaterMode(value: $0.value, name: $0.description) }
        var countdownRange: ClosedRange<Int>?
        if let r = countdown?.1.valueRange, r.count >= 2, r[0] <= r[1] { countdownRange = Int(r[0])...Int(r[1]) }

        return MiotMapping(
            power: power.0,
            powerToggle: powerToggle,
            target: target?.0,
            temperature: temperature?.0,
            mode: mode?.0,
            oscillation: oscillation?.0,
            countdown: countdown?.0,
            countdownRange: countdownRange,
            capabilities: HeaterCapabilities(
                model: model,
                targetRange: range,
                targetStep: step,
                modes: modes,
                hasTemperatureSensor: temperature != nil,
                hasOscillation: oscillation != nil,
                hasCountdown: countdown != nil
            )
        )
    }

    /// Highest released version for the model, else the highest version of any status.
    static func instanceType(in data: Data, model: String) -> String? {
        guard let list = try? JSONDecoder().decode(Instances.self, from: data) else { return nil }
        let candidates = list.instances.filter { $0.model == model }
        let released = candidates.filter { $0.status == "released" }
        return (released.isEmpty ? candidates : released).max { $0.version < $1.version }?.type
    }

    static func cacheURL(model: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiHeaterBar", isDirectory: true)
            .appendingPathComponent("spec-\(model).json")
    }

    /// Cached spec if present, otherwise discovered on miot-spec.org and cached.
    static func load(model: String) async throws -> MiotMapping {
        let cache = cacheURL(model: model)
        if let data = try? Data(contentsOf: cache), let mapping = try? parse(data, model: model) {
            return mapping
        }
        let base = "https://miot-spec.org/miot-spec-v2/"
        guard let type = instanceType(in: try await fetch(base + "instances?status=all"), model: model) else {
            throw HeaterError.unsupportedModel(model)
        }
        var components = URLComponents(string: base + "instance")!
        components.queryItems = [URLQueryItem(name: "type", value: type)]
        let data = try await fetch(components.url!.absoluteString)
        let mapping = try parse(data, model: model)
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: cache, options: .atomic)
        return mapping
    }

    private static func fetch(_ url: String) async throws -> Data {
        guard let u = URL(string: url),
              let (data, response) = try? await URLSession.shared.data(from: u),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { throw HeaterError.specUnavailable }
        return data
    }
}
