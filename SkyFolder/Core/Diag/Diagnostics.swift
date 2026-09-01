import Foundation
import CryptoKit

/// §10.2 診断画面が表示する内容。「何かおかしい」と感じたユーザーが最初に開く画面。
public struct DiagnosticsSnapshot: Sendable {
    public var osVersion: String = ""
    public var architecture: String = ""
    public var appVersion: String = ""

    /// SEC NOTE: 同梱バイナリのサプライチェーン。
    ///
    /// **T-G30 の注意**: `.app` の中の rclone は G0-3 で個別署名されるため、
    /// 実体のハッシュは配布物（署名前）のハッシュと**必ず異なる**。
    /// docs/BUNDLED.md と照合できるのは `rcloneDistributionSHA256` のほうで、
    /// これは fetch-rclone.sh が検証した値をリソース（rclone.sha256）として同梱したもの。
    /// `rcloneEmbeddedSHA256` は署名後の実体のハッシュで、照合対象ではない。
    public var rcloneVersion: String = ""
    public var rcloneDistributionSHA256: String = ""
    public var rcloneEmbeddedSHA256: String = ""
    public var mountTypes: [String] = []

    public var rcdStatus: RcdStatus = RcdStatus()

    /// M-05: `config/dump` は環境変数由来のリモートを返さない（空になる）。これは異常ではない。
    /// リモート定義の確認に使ってはならない。**Access Key も Secret も出ないため表示しても安全**。
    public var configDumpIsEmpty: Bool = true

    public var mounts: [RcMountPoint] = []
    public var vfsStats: RcVfsStats?
    public var connectionResults: [ConnectionTest.StepResult] = []

    /// §6.3 第 2 層: `DSDontWriteNetworkStores` の現在値。
    /// アプリが勝手に書き換えるのではなく、表示してユーザーの明示操作で設定する。
    public var dsDontWriteNetworkStores: Bool?

    /// SEC-G06 (a): どちらの keychain を使っているか。
    /// legacy だと `kSecAttrAccessibleWhenUnlocked` が効かず、画面ロック中も読める（M-24）。
    public var keychainMode: KeychainStore.Mode = .undetermined

    /// SEC-G04: 表示前にマスク済みのログ（直近 200 行）
    public var recentLog: [String] = []
    public var debugLoggingEnabled: Bool = false

    public init() {}
}

public enum DiagnosticsCollector {

    public static func environmentInfo() -> (os: String, arch: String, app: String) {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        #if arch(arm64)
        let arch = "arm64"
        #elseif arch(x86_64)
        let arch = "x86_64"
        #else
        let arch = "unknown"
        #endif
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "-"
        return (osString, arch, "\(short) (\(build))")
    }

    /// 同梱時に検証した「配布物の SHA-256」。docs/BUNDLED.md と照合できるのはこちら。
    public static func distributionSHA256() -> (sha: String, version: String)? {
        guard let url = Bundle.main.url(forResource: "rclone", withExtension: "sha256"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let parts = text.split(separator: " ", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let sha = parts.first, !sha.isEmpty else { return nil }
        return (sha, parts.count > 1 ? parts[1] : "")
    }

    /// 実体（署名後）の SHA-256。改ざん検知は codesign が担うため、これは参考値。
    public static func sha256(ofFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// §6.3 第 2 層: 現在値を読む（書き換えない）。
    public static func readDSDontWriteNetworkStores() -> Bool? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["read", "com.apple.desktopservices", "DSDontWriteNetworkStores"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }   // 未設定
        let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "1" || text?.lowercased() == "true"
    }

    /// ユーザーの明示操作でのみ呼ぶ。反映にはログアウトが必要である旨を UI に併記すること。
    @discardableResult
    public static func writeDSDontWriteNetworkStores(_ value: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        process.arguments = ["write", "com.apple.desktopservices",
                             "DSDontWriteNetworkStores", "-bool", value ? "true" : "false"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// SEC-G04: 直近 N 行をマスクして返す。
    public static func tailLog(at url: URL, lines: Int = 200, masker: LogMasker) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return [] }
        // 200 行に足りる程度だけ読む
        let window: UInt64 = 256 * 1024
        let start = size > window ? size - window : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
        else { return [] }
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return all.suffix(lines).map { masker.mask($0) }
    }
}
