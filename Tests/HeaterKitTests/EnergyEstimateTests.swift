import XCTest
import HeaterKit

final class EnergyEstimateTests: XCTestCase {
    func testWatts() {
        XCTAssertEqual(EnergyEstimate.watts(isOn: false, mode: "Heat", roomC: 18, deviceTarget: 22), 0)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Heat", roomC: 30, deviceTarget: 22), 2000)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Warm", roomC: 18, deviceTarget: 22), 1400)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Natural Wind", roomC: 18, deviceTarget: 22), 12)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Constant Temperature", roomC: 21, deviceTarget: 22), 2000)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Constant Temperature", roomC: 22, deviceTarget: 22), 1400)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: "Constant Temperature", roomC: 23, deviceTarget: 22), 12)
        XCTAssertEqual(EnergyEstimate.watts(isOn: true, mode: nil, roomC: nil, deviceTarget: nil), 2000)
    }

    func testSummarizeUsesPreviousRowAndCapsGaps() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func s(_ dt: TimeInterval, _ on: Bool, _ mode: String) -> LogSample {
            LogSample(time: t0 + dt, roomC: 19, isOn: on, mode: mode, deviceTarget: 22)
        }
        let samples = [
            s(0, true, "Heat"),     // 60 s at 2000 W
            s(60, true, "Warm"),    // 1 h gap, capped to 120 s at 1400 W
            s(3660, false, "Warm"), // off: not counted
            s(3720, true, "Heat"),  // last row: no interval
        ]
        let r = EnergyEstimate.summarize(samples)
        XCTAssertEqual(r.hours, 180.0 / 3600, accuracy: 1e-9)
        XCTAssertEqual(r.kWh, (60 * 2000 + 120 * 1400) / 3_600_000, accuracy: 1e-9)
    }

    func testParsesCSVLine() throws {
        let ts = EnergyEstimate.timestamp.string(from: Date(timeIntervalSince1970: 1_800_000_000))
        let s = try XCTUnwrap(LogSample(csvLine: "\(ts),19,1,Warm,24,0,1,20,poll,poll,"))
        XCTAssertEqual(s, LogSample(time: Date(timeIntervalSince1970: 1_800_000_000), roomC: 19, isOn: true, mode: "Warm", deviceTarget: 24))
        XCTAssertNil(LogSample(csvLine: "ts,room_c,on,mode,device_target,oscillating,auto,auto_target,action,source,error"))
        XCTAssertNil(LogSample(csvLine: "\(ts),19,1,Warm,24,0,1,20,poll,error,timeout"))
        let empty = try XCTUnwrap(LogSample(csvLine: "\(ts),,0,,,,0,20,poll,poll,"))
        XCTAssertNil(empty.roomC)
        XCTAssertNil(empty.mode)
    }
}
