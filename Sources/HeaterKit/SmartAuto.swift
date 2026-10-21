import Foundation

public enum HeatLevel: Sendable, Equatable { case strong, gentle }  // Heat / Warm
public enum AutoAction: Sendable, Equatable { case heat(HeatLevel), pause, keep }

/// Hysteresis thermostat that picks the cheapest mode able to reach the target.
public enum SmartAuto {
    public static let band = 0.5, boostGap = 1.5, minPause: TimeInterval = 600, emergencyGap = 1.5

    public static func decide(current: Double?, target: Double, isOn: Bool, pausedSince: Date?, now: Date) -> AutoAction {
        guard let current else { return isOn ? .keep : .heat(.gentle) }
        if current >= target + band { return isOn ? .pause : .keep }
        let level: HeatLevel = target - current >= boostGap ? .strong : .gentle
        guard !isOn else { return .heat(level) }
        // Avoid short cycles unless the room is getting really cold.
        if let pausedSince, now.timeIntervalSince(pausedSince) < minPause, current > target - emergencyGap { return .keep }
        return current <= target - band ? .heat(level) : .keep
    }

    /// Estimated seconds until current reaches target - band, from (time, temp) readings taken during the pause.
    /// Linear fit over readings; nil if span < 5 min or no drop observed (sensor is integer °C).
    public static func estimatedResume(readings: [(Date, Double)], target: Double, now: Date) -> TimeInterval? {
        guard let first = readings.first?.0, let last = readings.last?.0, last.timeIntervalSince(first) >= 300 else { return nil }
        let xs = readings.map { $0.0.timeIntervalSince(first) }, ys = readings.map(\.1)
        let n = Double(readings.count)
        let mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).map { ($0 - mx) * ($1 - mx) }.reduce(0, +)
        let sxy = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        guard sxx > 0, sxy < 0 else { return nil }
        let slope = sxy / sxx  // °C per second, negative
        let fittedNow = my + slope * (now.timeIntervalSince(first) - mx)
        return max(0, (target - band - fittedNow) / slope)
    }
}
