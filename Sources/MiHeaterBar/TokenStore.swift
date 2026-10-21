import Foundation

/// Stores the device token in a user-only (0600) file. The Keychain re-prompts on every
/// rebuild of an ad-hoc signed app, and this token only grants LAN control of the heater.
enum TokenStore {
    private static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MiHeaterBar/token")

    static func token() -> String? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { $0.isEmpty ? nil : $0 }
    }

    static func setToken(_ token: String) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600])
    }
}
