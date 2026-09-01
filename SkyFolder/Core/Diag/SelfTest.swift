import Foundation
import AppKit

/// `SkyFolder.app/Contents/MacOS/SkyFolder --selftest` で走る自己診断。
///
/// 目的は **実際に署名された .app の中で** 前提が成り立つことを確かめること。
/// 特に U-03（Hardened Runtime 下で同梱 rclone を子プロセス実行できるか）は、
/// Xcode の実行やユニットテストのプロセスでは Hardened Runtime が掛からないため、
/// この経路でしか確かめられない。
public enum SelfTest {

    public struct Result: Sendable {
        /// `warn` は「要件を満たせていないが、この署名では原理的に解消できない」ものに使う。
        /// 落とすと ad-hoc の開発ビルドが毎回失敗し、本当の失敗が埋もれるため終了コードには効かせない。
        /// **代わりに表示で必ず見えるようにする** — 黙って PASS にすると要件未達が台帳に載る。
        public enum Status: String, Sendable {
            case pass
            case warn
            case fail
        }

        public let id: String
        public let name: String
        public let status: Status
        public let detail: String

        /// 終了コードの判定に使う（`--selftest` は `allSatisfy(\.passed)` で 0 / 1 を決める）。
        public var passed: Bool { status != .fail }
    }

    public static func run(rcloneURL: URL?) async -> [Result] {
        var results: [Result] = []

        func add(_ id: String, _ name: String, _ passed: Bool, _ detail: String) {
            results.append(Result(id: id, name: name, status: passed ? .pass : .fail, detail: detail))
        }

        func add(_ id: String, _ name: String, _ status: Result.Status, _ detail: String) {
            results.append(Result(id: id, name: name, status: status, detail: detail))
        }

        // --- 同梱バイナリの所在 ---
        guard let rcloneURL else {
            add("T-G01", "同梱 rclone の取得", false,
                "Bundle.main.url(forResource:) が nil を返した")
            return results
        }
        add("BUNDLE", "同梱 rclone の所在", FileManager.default.isExecutableFile(atPath: rcloneURL.path),
            rcloneURL.path)

        // --- T-G01 / U-03: Hardened Runtime 下での子プロセス実行 ---
        let paths = AppPaths()
        let supervisor = RcdSupervisor(rcloneURL: rcloneURL, paths: paths)
        do {
            let info = try supervisor.probeVersion()
            add("T-G01", "同梱 rclone を Process で実行して version を取得", true, info.version)
            add("U-03", "Hardened Runtime 下での子プロセス実行", true,
                "entitlement の現状で成功した（このバイナリの署名: 下記 codesign を参照）")
            let ok = RcdSupervisor.versionAtLeast(info.version, "1.68")
            add("T-G01b", "v1.68 以上", ok, info.version)
        } catch {
            add("T-G01", "同梱 rclone を Process で実行して version を取得", false,
                String(describing: error))
            add("U-03", "Hardened Runtime 下での子プロセス実行", false,
                "失敗。com.apple.security.cs.disable-library-validation の要否を再検討すること")
            return results
        }

        // --- T-G30: SHA-256 の照合 ---
        // .app 内の rclone は G0-3 で個別署名されるため、実体のハッシュは配布物のそれと必ず異なる。
        // 照合できるのは fetch-rclone.sh が検証して同梱した「配布物のハッシュ」のほう。
        let expected = "f52ccc22e6fe61ea5791f0e186db323155ad1cc1b6dfe547f4bc665bea57a2dd"
        let distribution = DiagnosticsCollector.distributionSHA256()
        add("T-G30", "配布物の SHA-256 が docs/BUNDLED.md と一致",
            distribution?.sha == expected, distribution?.sha ?? "(rclone.sha256 が同梱されていない)")
        let embedded = DiagnosticsCollector.sha256(ofFileAt: rcloneURL) ?? ""
        add("T-G30b", "署名後の実体は配布物と異なる（署名しているので正常）",
            embedded != expected, embedded)

        // --- G0 AC / A-01〜A-06: アセットが解決できるか ---
        // メニューバーのアイコンは目視では確認しづらい（項目が多いと macOS が省略するため）。
        // アセットカタログから解決できることを機械的に確かめる。
        let appIcon = NSImage(named: NSImage.applicationIconName)
        add("A-01", "AppIcon が解決できる", appIcon != nil,
            appIcon.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")

        let menuBar = NSImage(named: "MenuBarIcon")
        add("A-06", "メニューバー用テンプレート画像が解決できる", menuBar != nil,
            menuBar.map { "\(Int($0.size.width))x\(Int($0.size.height)) isTemplate=\($0.isTemplate)" }
                ?? "nil")
        add("A-06b", "テンプレート画像として登録されている", menuBar?.isTemplate == true,
            "isTemplate=\(menuBar?.isTemplate.description ?? "nil")")

        let logo = NSImage(named: "Logo")
        add("A-05", "ロゴが解決できる", logo != nil,
            logo.map { "\(Int($0.size.width))x\(Int($0.size.height))" } ?? "nil")

        for colorName in ["BrandColor", "PublicWarningColor", "AccentColor"] {
            add("COLOR", "色 \(colorName) が解決できる", NSColor(named: colorName) != nil, "")
        }

        // --- T-G02 / T-G03 / T-G05: rcd を起動して RC API を叩く ---
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(AppIdentity.bundleIdentifier).selftest.\(UUID().uuidString)",
                                    isDirectory: true)
        try? AppPaths.ensureDirectory(work, mode: 0o700)
        defer { try? FileManager.default.removeItem(at: work) }

        let logFile = work.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        do {
            let spec = RcdLaunchSpec(rcloneURL: rcloneURL,
                                     localRemoteName: "loc",
                                     cacheDir: work.appendingPathComponent("cache"),
                                     logFile: logFile)
            let endpoint = try await supervisor.start(specFactory: { spec })
            add("T-G02", "rcd を 127.0.0.1:0 で起動し実ポートを取得", true,
                "port=\(endpoint.port)")

            let client = RcClient(endpoint: endpoint)
            let version = try await client.coreVersion()
            add("T-G02b", "core/version に Basic 認証付きで応答がある", true, version.version)

            // T-G03: 認証なしは 401（--rc-no-auth になっていないこと・SEC-G01）
            var request = URLRequest(url: endpoint.baseURL.appendingPathComponent(RcPath.mountTypes))
            request.httpMethod = "POST"
            request.httpBody = Data("{}".utf8)
            let status = (try? await URLSession(configuration: .ephemeral).data(for: request))
                .map { ($0.1 as? HTTPURLResponse)?.statusCode ?? -1 } ?? -1
            add("T-G03", "認証情報なしの rc アクセスが 401 になる", status == 401, "HTTP \(status)")

            // T-G05 / CRIT-01
            let types = try await client.mountTypes()
            add("T-G05", "mount/types に nfsmount が含まれる", types.contains("nfsmount"),
                types.joined(separator: ", "))

            await supervisor.stop()
            add("SHUTDOWN", "rcd を停止できる", true, "")
        } catch {
            add("T-G02", "rcd を起動して RC API を叩く", false, String(describing: error))
            await supervisor.stop()
        }

        // --- SEC-G06: Keychain（data protection keychain）が実際に使えるか ---
        // `kSecUseDataProtectionKeychain` は entitlement を要求するため、
        // **署名済みの .app の中でしか確かめられない**（テストバンドルでは errSecMissingEntitlement）。
        let keychain = KeychainStore(service: "\(AppIdentity.bundleIdentifier).selftest")
        let probeAccount = "selftest.\(UUID().uuidString)"
        do {
            try keychain.write("probe", account: probeAccount)
            let readBack = try keychain.read(account: probeAccount)
            // **どちらの keychain へ書けたかを実際に読む。**
            // `KeychainStore` は data protection が使えなければ legacy へ落ちて成功を返すので、
            // 「書けた」だけでは SEC-G06 (a) の成否が分からない。delete より前に取る。
            let mode = keychain.activeMode
            try keychain.delete(account: probeAccount)

            if readBack != "probe" {
                add("SEC-G06", "Keychain に書いて読んで消せる", Result.Status.fail,
                    "書き戻した値が一致しない: \(readBack)")
            } else if mode.satisfiesLockProtection {
                add("SEC-G06", "Keychain に書いて読んで消せる", Result.Status.pass,
                    "activeMode=\(mode.rawValue) — kSecAttrAccessibleWhenUnlocked が効く。SEC-G06 (a) 成立")
            } else {
                add("SEC-G06", "Keychain に書いて読んで消せる", Result.Status.warn,
                    "activeMode=\(mode.rawValue) — data protection keychain に書けず login.keychain へ落ちた。"
                    + "kSecAttrAccessible は無視され、画面ロック中も読める。SEC-G06 (a) は未達。"
                    + "Developer ID 署名で再確認すること（G5-2）")
            }
        } catch let error as KeychainError {
            var detail = String(describing: error)
            if case .writeFailed(let status) = error, status == -34018 {
                detail = "errSecMissingEntitlement (-34018) — data protection keychain には "
                    + "application-identifier entitlement が要る。ad-hoc 署名では付与できないため、"
                    + "Developer ID 署名で再確認すること（G5-2）"
            }
            add("SEC-G06", "Keychain に書いて読んで消せる", false, detail)
        } catch {
            add("SEC-G06", "Keychain に書いて読んで消せる", false, String(describing: error))
        }

        // --- T-G10: 既定の rclone.conf を汚さない（§4.1 MUST）---
        let userConf = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/rclone/rclone.conf")
        add("T-G10", "~/.config/rclone/rclone.conf を作らない",
            !FileManager.default.fileExists(atPath: userConf.path),
            userConf.path)

        return results
    }

    /// 標準出力に整形して出す。
    public static func report(_ results: [Result]) -> String {
        var lines: [String] = []
        let passed = results.filter { $0.status == .pass }.count
        let warned = results.filter { $0.status == .warn }.count
        // 警告を件数として見出しに出す。ここに出さないと WARN 行は本文に埋もれる。
        let headline = warned > 0
            ? "SkyFolder 自己診断: \(passed)/\(results.count) 通過（警告 \(warned) 件）"
            : "SkyFolder 自己診断: \(passed)/\(results.count) 通過"
        lines.append(headline)
        lines.append(String(repeating: "-", count: 60))
        for r in results {
            let label: String
            switch r.status {
            case .pass: label = "PASS"
            case .warn: label = "WARN"
            case .fail: label = "FAIL"
            }
            lines.append("\(label)  \(r.id.padding(toLength: 8, withPad: " ", startingAt: 0)) \(r.name)")
            if !r.detail.isEmpty { lines.append("      \(r.detail)") }
        }
        return lines.joined(separator: "\n")
    }
}
