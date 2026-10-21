import XCTest
import HeaterKit

final class SmartAutoTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func decide(_ current: Double?, isOn: Bool, pausedAgo: TimeInterval? = nil) -> AutoAction {
        SmartAuto.decide(current: current, target: 20, isOn: isOn, pausedSince: pausedAgo.map { now - $0 }, now: now)
    }

    func testNoSensor() {
        XCTAssertEqual(decide(nil, isOn: false), .heat(.gentle))
        XCTAssertEqual(decide(nil, isOn: true), .keep)
    }

    func testPausesAboveBand() {
        XCTAssertEqual(decide(20.5, isOn: true), .pause)  // boundary
        XCTAssertEqual(decide(23, isOn: true), .pause)
        XCTAssertEqual(decide(23, isOn: false), .keep)
    }

    func testOnPicksLevelByGap() {
        XCTAssertEqual(decide(20.4, isOn: true), .heat(.gentle))
        XCTAssertEqual(decide(19, isOn: true), .heat(.gentle))
        XCTAssertEqual(decide(18.5, isOn: true), .heat(.strong))  // boundary
        XCTAssertEqual(decide(15, isOn: true), .heat(.strong))
    }

    func testOffResumesBelowBand() {
        XCTAssertEqual(decide(20, isOn: false), .keep)
        XCTAssertEqual(decide(19.5, isOn: false), .heat(.gentle))  // boundary
        XCTAssertEqual(decide(18, isOn: false), .heat(.strong))
    }

    func testMinPauseUnlessEmergency() {
        XCTAssertEqual(decide(19, isOn: false, pausedAgo: 300), .keep)
        XCTAssertEqual(decide(18.5, isOn: false, pausedAgo: 300), .heat(.strong))  // emergency boundary
        XCTAssertEqual(decide(19, isOn: false, pausedAgo: 600), .heat(.gentle))
    }

    func testEstimatedResume() throws {
        // 1 °C per 10 min: 21 -> 20 over 10 min; next tick at 20, target - band = 19.5.
        let readings: [(Date, Double)] = [(now - 600, 21), (now - 300, 20.5), (now, 20)]
        XCTAssertEqual(try XCTUnwrap(SmartAuto.estimatedResume(readings: readings, target: 20, now: now)), 300, accuracy: 0.001)
        XCTAssertEqual(SmartAuto.estimatedResume(readings: readings, target: 21, now: now), 0)
    }

    func testEstimatedResumeNeedsSpanAndDrop() {
        XCTAssertNil(SmartAuto.estimatedResume(readings: [], target: 20, now: now))
        XCTAssertNil(SmartAuto.estimatedResume(readings: [(now - 200, 22), (now, 21)], target: 20, now: now))
        XCTAssertNil(SmartAuto.estimatedResume(readings: [(now - 600, 21), (now, 21)], target: 20, now: now))
        XCTAssertNil(SmartAuto.estimatedResume(readings: [(now - 600, 21), (now, 22)], target: 20, now: now))
    }
}
