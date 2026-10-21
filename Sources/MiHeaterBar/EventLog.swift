import Foundation
import HeaterKit

/// Monthly CSV log in ~/Library/Application Support/MiHeaterBar/log-YYYY-MM.csv.
enum EventLog {
    static let header = "ts,room_c,on,mode,device_target,oscillating,auto,auto_target,action,source,error"

    static let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MiHeaterBar", isDirectory: true)

    static func fileURL(for date: Date) -> URL {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        return directory.appendingPathComponent(String(format: "log-%04d-%02d.csv", c.year!, c.month!))
    }

    static func append(state: HeaterState?, modeName: String?, auto: Bool, autoTarget: Double,
                       action: String, source: String, error: String = "") {
        func num(_ v: Double?) -> String { v.map(formatTemp) ?? "" }
        func flag(_ v: Bool?) -> String { v.map { $0 ? "1" : "0" } ?? "" }
        let now = Date()
        let fields = [
            EnergyEstimate.timestamp.string(from: now), num(state?.currentTemperature), flag(state?.isOn),
            modeName ?? "", num(state?.targetTemperature), flag(state?.oscillating), flag(auto), num(autoTarget),
            action, source, error.replacingOccurrences(of: ",", with: ";").replacingOccurrences(of: "\n", with: " "),
        ]
        let url = fileURL(for: now)
        let line = Data((fields.joined(separator: ",") + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? (Data((header + "\n").utf8) + line).write(to: url, options: .atomic)
        }
    }

    /// Samples since `start`, from this month's and last month's files.
    static func samples(since start: Date) -> [LogSample] {
        let months = Set([fileURL(for: start), fileURL(for: Date())])
        return months
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n").compactMap { LogSample(csvLine: String($0)) } }
            .filter { $0.time >= start }
            .sorted { $0.time < $1.time }
    }
}
