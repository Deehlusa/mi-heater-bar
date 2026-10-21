import CommonCrypto
import CryptoKit
import Foundation
import Network

// Binary framing and AES for the miIO protocol.
enum MiIOCodec {
    static let hello = Data([0x21, 0x31, 0x00, 0x20]) + Data(repeating: 0xff, count: 28)

    struct Header: Equatable {
        let did: UInt32
        let stamp: UInt32
    }

    static func md5(_ data: Data) -> Data { Data(Insecure.MD5.hash(data: data)) }

    static func encrypt(_ plain: Data, token: Data) -> Data {
        aes(CCOperation(kCCEncrypt), plain, token: token)!  // encryption with a 16-byte key cannot fail
    }

    static func decrypt(_ cipher: Data, token: Data) -> Data? {
        aes(CCOperation(kCCDecrypt), cipher, token: token)
    }

    static func encode(_ payload: Data, token: Data, did: UInt32, stamp: UInt32) -> Data {
        let body = encrypt(payload, token: token)
        var header = Data([0x21, 0x31])
        header.append(be16(UInt16(32 + body.count)))
        header.append(Data(count: 4))
        header.append(be32(did))
        header.append(be32(stamp))
        let checksum = md5(header + token + body)
        return header + checksum + body
    }

    /// Parses any packet header (including hello replies) without checking the checksum.
    static func header(_ packet: Data) -> Header? {
        let p = Data(packet)
        guard p.count >= 32, p[0] == 0x21, p[1] == 0x31, Int(u16(p, 2)) == p.count else { return nil }
        return Header(did: u32(p, 8), stamp: u32(p, 12))
    }

    /// Verifies the checksum and returns the decrypted payload.
    static func decode(_ packet: Data, token: Data) -> (Header, Data)? {
        let p = Data(packet)
        guard let h = header(p) else { return nil }
        let body = p.subdata(in: 32..<p.count)
        guard md5(p.subdata(in: 0..<16) + token + body) == p.subdata(in: 16..<32) else { return nil }
        if body.isEmpty { return (h, Data()) }
        guard let plain = decrypt(body, token: token) else { return nil }
        return (h, plain)
    }

    private static func aes(_ op: CCOperation, _ input: Data, token: Data) -> Data? {
        let key = md5(token)
        let iv = md5(key + token)
        var out = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = out.count
        var moved = 0
        let status = out.withUnsafeMutableBytes { o in
            input.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                i.baseAddress, input.count, o.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    private static func be16(_ v: UInt16) -> Data { Data([UInt8(v >> 8), UInt8(v & 0xff)]) }
    private static func be32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (24 - 8 * $0)) & 0xff) }) }
    private static func u16(_ d: Data, _ at: Int) -> UInt16 { UInt16(d[at]) << 8 | UInt16(d[at + 1]) }
    private static func u32(_ d: Data, _ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 << 8 | UInt32(d[at + $1]) } }
}

// MIoT property value as sent/received in JSON.
enum PropValue: Codable, Sendable, Equatable {
    case bool(Bool)
    case number(Double)
    case string(String)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else { self = .string(try c.decode(String.self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        }
    }

    var bool: Bool? { if case .bool(let b) = self { b } else if case .number(let n) = self { n != 0 } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
}

struct PropRequest: Encodable, Sendable {
    var did = "heater"
    let siid: Int
    let piid: Int
    var value: PropValue? = nil
}

struct ActionRequest: Encodable, Sendable {
    var did = "heater"
    let siid: Int
    let aiid: Int
    var `in`: [Int] = []
}

struct ActionResult: Decodable, Sendable {
    let code: Int
}

struct PropResult: Decodable, Sendable {
    let siid: Int
    let piid: Int
    let code: Int
    let value: PropValue?
}

// UDP transport: hello handshake, request/response with timeout and one retry.
actor MiIO {
    static let port: NWEndpoint.Port = 54321
    static let timeout: TimeInterval = 3

    private struct Session {
        let did: UInt32
        let stamp: UInt32
        let at: Date
    }

    private struct Request<P: Encodable>: Encodable {
        let id: Int
        let method: String
        let params: P
    }

    private struct Response<R: Decodable>: Decodable {
        struct RPCError: Decodable { let code: Int }
        let id: Int
        let result: R?
        let error: RPCError?
    }

    private struct EmptyParams: Encodable, Sendable {
        func encode(to encoder: Encoder) throws { _ = encoder.unkeyedContainer() }
    }

    private let host: NWEndpoint.Host
    private let token: Data
    private let queue = DispatchQueue(label: "miio")
    private var connection: NWConnection?
    private var session: Session?
    private var nextID = Int.random(in: 1..<10_000)
    private var tail: Task<Void, Never>?

    init(host: String, token: Data) {
        self.host = NWEndpoint.Host(host)
        self.token = token
    }

    func call<R: Decodable & Sendable>(_ method: String, as: R.Type) async throws -> R {
        try await call(method, params: EmptyParams(), as: R.self)
    }

    /// Requests are chained so only one is in flight at a time.
    func call<P: Encodable & Sendable, R: Decodable & Sendable>(_ method: String, params: P, as: R.Type) async throws -> R {
        let previous = tail
        let task = Task { () async throws -> R in
            await previous?.value
            return try await self.perform(method, params: params, as: R.self)
        }
        tail = Task { _ = await task.result }
        return try await task.value
    }

    private func perform<P: Encodable, R: Decodable>(_ method: String, params: P, as: R.Type) async throws -> R {
        for attempt in 0..<2 {
            do {
                return try await attemptCall(method, params: params, as: R.self)
            } catch HeaterError.timeout where attempt == 0 {
                continue
            }
        }
        throw HeaterError.timeout
    }

    private func attemptCall<P: Encodable, R: Decodable>(_ method: String, params: P, as: R.Type) async throws -> R {
        let s = try await handshake()
        let id = nextID
        nextID += 1
        let payload = try JSONEncoder().encode(Request(id: id, method: method, params: params))
        let stamp = s.stamp &+ UInt32(max(0, Date().timeIntervalSince(s.at)))
        let reply = try await exchange(MiIOCodec.encode(payload, token: token, did: s.did, stamp: stamp))
        guard let (_, plain) = MiIOCodec.decode(reply, token: token) else { throw HeaterError.invalidResponse }
        var json = plain
        while json.last == 0 { json.removeLast() }
        guard let response = try? JSONDecoder().decode(Response<R>.self, from: json), response.id == id else {
            throw HeaterError.invalidResponse
        }
        if let error = response.error { throw HeaterError.device(code: error.code) }
        guard let result = response.result else { throw HeaterError.invalidResponse }
        return result
    }

    private func handshake() async throws -> Session {
        if let session { return session }
        let reply = try await exchange(MiIOCodec.hello)
        guard let h = MiIOCodec.header(reply) else { throw HeaterError.invalidResponse }
        let s = Session(did: h.did, stamp: h.stamp, at: Date())
        session = s
        return s
    }

    /// Sends one datagram and waits for one reply. On timeout the socket and session are dropped,
    /// so the next attempt starts with a fresh hello.
    private func exchange(_ packet: Data) async throws -> Data {
        let conn: NWConnection
        if let connection {
            conn = connection
        } else {
            conn = NWConnection(host: host, port: Self.port, using: .udp)
            conn.start(queue: queue)
            connection = conn
        }
        do {
            return try await Self.roundTrip(conn, packet, queue: queue, timeout: Self.timeout)
        } catch {
            conn.cancel()
            connection = nil
            session = nil
            throw error
        }
    }

    private final class Once: @unchecked Sendable {
        var done = false  // only touched on the connection queue
    }

    private static func roundTrip(_ conn: NWConnection, _ packet: Data, queue: DispatchQueue, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let once = Once()
            let finish: @Sendable (Result<Data, Error>) -> Void = { result in
                guard !once.done else { return }
                once.done = true
                cont.resume(with: result)
            }
            queue.async {
                conn.send(content: packet, completion: .contentProcessed { error in
                    if error != nil { finish(.failure(HeaterError.timeout)) }
                })
                conn.receiveMessage { data, _, _, _ in
                    if let data, !data.isEmpty { finish(.success(data)) } else { finish(.failure(HeaterError.timeout)) }
                }
                queue.asyncAfter(deadline: .now() + timeout) { finish(.failure(HeaterError.timeout)) }
            }
        }
    }
}

extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0, hex.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
