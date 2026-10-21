import XCTest
@testable import HeaterKit

final class MiIOTests: XCTestCase {
    let token = Data(hex: "9f86d081884c7d659a2feaa0c55ad015")!
    let payload = Data(#"{"id":1,"method":"miIO.info","params":[]}"#.utf8)
    // Generated with fake_heater.encode (Python `cryptography`) for token/did/stamp above.
    let pythonPacket = Data(hex: "213100500000000001020304000012341f52251adfeb40a207ea0b5e6648e4cf16437deedbbf337897551ea47f67eebe51e9630c30af0471f701d00dcdecc1015be879176a6b737eee406a3f282ef584")!

    func testEncryptDecryptRoundTrip() {
        let cipher = MiIOCodec.encrypt(payload, token: token)
        XCTAssertEqual(cipher.count % 16, 0)
        XCTAssertNotEqual(cipher, payload)
        XCTAssertEqual(MiIOCodec.decrypt(cipher, token: token), payload)
    }

    func testPacketRoundTripAndChecksum() throws {
        let packet = MiIOCodec.encode(payload, token: token, did: 0xDEADBEEF, stamp: 42)
        XCTAssertEqual(packet.count, 32 + MiIOCodec.encrypt(payload, token: token).count)
        let (header, plain) = try XCTUnwrap(MiIOCodec.decode(packet, token: token))
        XCTAssertEqual(header, .init(did: 0xDEADBEEF, stamp: 42))
        XCTAssertEqual(plain, payload)

        var tampered = packet
        tampered[tampered.count - 1] ^= 0x01
        XCTAssertNil(MiIOCodec.decode(tampered, token: token))
        XCTAssertNil(MiIOCodec.decode(packet, token: Data(repeating: 0, count: 16)))
    }

    func testPythonVectorDecodes() throws {
        let (header, plain) = try XCTUnwrap(MiIOCodec.decode(pythonPacket, token: token))
        XCTAssertEqual(header, .init(did: 0x01020304, stamp: 0x1234))
        XCTAssertEqual(plain, payload)
    }

    func testSwiftEncodingMatchesPython() {
        // AES-CBC with a fixed IV is deterministic, so byte equality means Python decodes Swift's packet.
        XCTAssertEqual(MiIOCodec.encode(payload, token: token, did: 0x01020304, stamp: 0x1234).hex, pythonPacket.hex)
    }

    func testHelloAndHeader() throws {
        XCTAssertEqual(MiIOCodec.hello.count, 32)
        XCTAssertEqual(MiIOCodec.hello.prefix(4), Data([0x21, 0x31, 0x00, 0x20]))
        var reply = Data([0x21, 0x31, 0x00, 0x20, 0, 0, 0, 0, 0x0A, 0x1B, 0x2C, 0x3D, 0, 0, 0x03, 0xE8])
        reply.append(Data(repeating: 0xff, count: 16))
        XCTAssertEqual(MiIOCodec.header(reply), .init(did: 0x0A1B2C3D, stamp: 1000))
        XCTAssertNil(MiIOCodec.header(reply.prefix(31)))
    }

    func testTokenValidation() {
        XCTAssertNoThrow(try Heater(ip: "127.0.0.1", token: "00112233445566778899aabbccddeeff"))
        XCTAssertThrowsError(try Heater(ip: "127.0.0.1", token: "0011"))
        XCTAssertThrowsError(try Heater(ip: "127.0.0.1", token: "zz112233445566778899aabbccddeeff"))
        XCTAssertThrowsError(try Heater(ip: "127.0.0.1", token: "+0112233445566778899aabbccddeeff"))
    }
}
