import Foundation
import Security

/// GitHub 的令牌：先看环境变量，再看钥匙串里手填的，最后读本机 gh CLI 的登录态。
/// 只是为了让搜索额度从 10 次/分变成 30 次/分，没有也能跑（少跑几条查询）。
enum Auth {
    static let keychainService = "app.openfeed.github"
    static let keychainAccount = "token"

    static var token: String? {
        if let value = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !value.isEmpty { return value }
        if let value = ProcessInfo.processInfo.environment["GH_TOKEN"], !value.isEmpty { return value }
        if let value = keychainToken, !value.isEmpty { return value }
        return ghCLIToken
    }

    static var source: String {
        if ProcessInfo.processInfo.environment["GITHUB_TOKEN"] != nil { return "环境变量" }
        if keychainToken != nil { return "钥匙串" }
        if ghCLIToken != nil { return "gh CLI" }
        return "未授权"
    }

    static var keychainToken: String? {
        keychainToken(service: keychainService, account: keychainAccount)
    }

    static func keychainToken(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8)
        else { return nil }
        return token
    }

    static func saveKeychain(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        if trimmed.isEmpty {
            SecItemDelete(base as CFDictionary)
            return
        }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(trimmed.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    /// gh 的令牌在钥匙串里（2.x 起不再写 hosts.yml），所以只问它一句 `gh auth token`。
    /// 67ms，一次启动问一遍，够快。
    static var ghCLIToken: String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/gh").path
        ]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["auth", "token"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let token = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return token.isEmpty ? nil : token
    }
}
