import Foundation

/// One row of the app's CSV event log, reduced to what the energy estimate needs.
public struct LogSample: Equatable, Sendable {
    public var time: Date
    public var roomC: Double?
    public var isOn: Bool
    public var mode: String?
    public var deviceTarget: Double?

    public init(time: Date, roomC: Double?, isOn: Bool, mode: String?, deviceTarget: Double?) {
        self.time = time
        self.roomC = roomC
        self.isOn = isOn
        self.mode = mode
        self.deviceTarget = deviceTarget
    }

    /// Parses `ts,room_c,on,mode,device_target,...`; nil for the header, malformed and error rows.
    public init?(csvLine: String) {
        let f = csvLine.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 11, f[9] != "error", let time = EnergyEstimate.timestamp.date(from: f[0]) else { return nil }
        self.init(time: time, roomC: Double(f[1]), isOn: f[2] == "1", mode: f[3].isEmpty ? nil : f[3], deviceTarget: Double(f[4]))
    }
}

/// Estimated consumption from the logged mode (the device doesn't meter power).
public enum EnergyEstimate {
    public static let timestamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        return f
    }()

    /// Rated power for leshow.heater.nfj3lx; Constant Temperature steps down as the room nears the target.
    public static func watts(isOn: Bool, mode: String?, roomC: Double?, deviceTarget: Double?) -> Double {
        guard isOn else { return 0 }
        switch mode {
        case "Warm": return 1400
        case "Natural Wind": return 12
        case "Constant Temperature":
            guard let roomC, let deviceTarget else { return 2000 }
            return roomC < deviceTarget ? 2000 : roomC == deviceTarget ? 1400 : 12
        default: return 2000  // Heat, or unknown modes: assume full power
        }
    }

    /// Hours on and kWh; each interval (capped at maxGap so gaps don't count) uses the earlier sample's state.
    public static func summarize(_ samples: [LogSample], maxGap: TimeInterval = 120) -> (hours: Double, kWh: Double) {
        var seconds = 0.0, joules = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) where a.isOn {
            let dt = min(max(b.time.timeIntervalSince(a.time), 0), maxGap)
            seconds += dt
            joules += dt * watts(isOn: true, mode: a.mode, roomC: a.roomC, deviceTarget: a.deviceTarget)
        }
        return (seconds / 3600, joules / 3_600_000)
    }
}
