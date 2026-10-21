import XCTest
@testable import HeaterKit

final class MiotSpecTests: XCTestCase {
    func fixture(_ model: String) throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: model, withExtension: "json", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    func testMC2A() throws {
        let m = try MiotSpec.parse(fixture("zhimi.heater.mc2a"), model: "zhimi.heater.mc2a")
        XCTAssertEqual(m.power, MiotProp(siid: 2, piid: 1))
        XCTAssertEqual(m.target, MiotProp(siid: 2, piid: 5))
        XCTAssertEqual(m.temperature, MiotProp(siid: 4, piid: 7))
        XCTAssertNil(m.mode)
        XCTAssertEqual(m.capabilities.model, "zhimi.heater.mc2a")
        XCTAssertEqual(m.capabilities.targetRange, 18...28)
        XCTAssertEqual(m.capabilities.targetStep, 1)
        XCTAssertEqual(m.capabilities.modes, [])
        XCTAssertTrue(m.capabilities.hasTemperatureSensor)
        XCTAssertFalse(m.capabilities.hasOscillation)
        XCTAssertTrue(m.capabilities.hasCountdown)
    }

    func testNFJ3LX() throws {
        let m = try MiotSpec.parse(fixture("leshow.heater.nfj3lx"), model: "leshow.heater.nfj3lx")
        XCTAssertEqual(m.power, MiotProp(siid: 2, piid: 1))
        XCTAssertEqual(m.target, MiotProp(siid: 2, piid: 3))
        XCTAssertEqual(m.temperature, MiotProp(siid: 4, piid: 7))
        XCTAssertEqual(m.mode, MiotProp(siid: 2, piid: 5))
        XCTAssertEqual(m.oscillation, MiotProp(siid: 8, piid: 1))
        XCTAssertEqual(m.countdown, MiotProp(siid: 3, piid: 1))
        XCTAssertEqual(m.countdownRange, 0...480)
        XCTAssertEqual(m.capabilities.targetRange, 22...28)
        XCTAssertEqual(m.capabilities.modes.map(\.name), ["Constant Temperature", "Heat", "Warm", "Natural Wind"])
        XCTAssertTrue(m.capabilities.hasOscillation)
        XCTAssertTrue(m.capabilities.hasCountdown)
    }

    func testSwingServiceIsOscillation() throws {
        let json = Data("""
        {"services":[
          {"iid":2,"type":"urn:miot-spec-v2:service:heater:00007802:x:1","properties":[{"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:x:1"}]},
          {"iid":5,"type":"urn:miot-spec-v2:service:swing:0000780B:x:1","properties":[{"iid":2,"type":"urn:miot-spec-v2:property:on:00000006:x:1"}]}
        ]}
        """.utf8)
        let m = try MiotSpec.parse(json, model: "x")
        XCTAssertEqual(m.oscillation, MiotProp(siid: 5, piid: 2))
        XCTAssertFalse(m.capabilities.hasCountdown)
        XCTAssertNil(m.countdownRange)
    }

    func testMA5() throws {
        let m = try MiotSpec.parse(fixture("zhimi.heater.ma5"), model: "zhimi.heater.ma5")
        XCTAssertEqual(m.power, MiotProp(siid: 2, piid: 1))
        XCTAssertEqual(m.target, MiotProp(siid: 2, piid: 5))
        XCTAssertEqual(m.temperature, MiotProp(siid: 4, piid: 7), "environment.temperature wins over heater.temperature")
        XCTAssertEqual(m.mode, MiotProp(siid: 2, piid: 7))
        XCTAssertEqual(m.capabilities.targetRange, 16...28)
        XCTAssertEqual(m.capabilities.modes, [
            HeaterMode(value: 0, name: "Auto"),
            HeaterMode(value: 1, name: "LL Heating"),
            HeaterMode(value: 2, name: "Continus Heating"),
        ])
    }

    func testMissingPowerIsUnsupported() {
        let json = Data(#"{"services":[{"iid":2,"type":"urn:miot-spec-v2:service:fan:00007808:x:1","properties":[]}]}"#.utf8)
        XCTAssertThrowsError(try MiotSpec.parse(json, model: "x")) { error in
            guard case HeaterError.unsupportedModel("x") = error else { return XCTFail("\(error)") }
        }
    }

    func testFallbacksHeaterTemperatureAndHeatLevel() throws {
        let json = Data("""
        {"services":[{"iid":2,"type":"urn:miot-spec-v2:service:heater:00007802:x:1","properties":[
          {"iid":1,"type":"urn:miot-spec-v2:property:on:00000006:x:1"},
          {"iid":3,"type":"urn:miot-spec-v2:property:heat-level:00000047:x:1","value-list":[{"value":1,"description":"Low"},{"value":2,"description":"High"}]},
          {"iid":4,"type":"urn:miot-spec-v2:property:temperature:00000020:x:1","value-range":[-30,100,1]}
        ]}]}
        """.utf8)
        let m = try MiotSpec.parse(json, model: "x")
        XCTAssertEqual(m.temperature, MiotProp(siid: 2, piid: 4))
        XCTAssertEqual(m.mode, MiotProp(siid: 2, piid: 3))
        XCTAssertEqual(m.capabilities.modes.map(\.name), ["Low", "High"])
        XCTAssertNil(m.capabilities.targetRange)
    }

    func testInstanceSelection() {
        let json = Data("""
        {"instances":[
          {"model":"a","type":"urn:a:1","version":1,"status":"released"},
          {"model":"a","type":"urn:a:3","version":3,"status":"debug"},
          {"model":"a","type":"urn:a:2","version":2,"status":"released"},
          {"model":"b","type":"urn:b:1","version":1,"status":"debug"},
          {"model":"b","type":"urn:b:2","version":2,"status":"preview"}
        ]}
        """.utf8)
        XCTAssertEqual(MiotSpec.instanceType(in: json, model: "a"), "urn:a:2")
        XCTAssertEqual(MiotSpec.instanceType(in: json, model: "b"), "urn:b:2")
        XCTAssertNil(MiotSpec.instanceType(in: json, model: "c"))
    }
}
