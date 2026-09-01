import Foundation

/// §4.3 のバリデーション結果。エラーは該当フィールド直下にインライン表示する（ダイアログにしない）。
public struct ValidationIssue: Sendable, Equatable, Identifiable {
    public enum Severity: Sendable, Equatable { case error, warning }

    /// §4.3 の ID（V-01 等）
    public let rule: String
    public let severity: Severity
    /// UI 上のどのフィールドに紐づくか。`buckets[0].bucketName` のような経路表現。
    public let field: String
    public let message: String

    public var id: String { "\(rule):\(field)" }

    public init(rule: String, severity: Severity = .error, field: String, message: String) {
        self.rule = rule
        self.severity = severity
        self.field = field
        self.message = message
    }
}

/// §4.3: 接続テスト実行前のクライアント側検証。
public enum ProfileValidator {

    // MARK: - 個別ルール

    /// V-01: `^[0-9a-f]{32}$`。ダッシュボードから貼り付けたときの前後空白は自動 trim。
    public static func normalizeAccountId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    public static func isValidAccountId(_ value: String) -> Bool {
        let s = normalizeAccountId(value)
        return s.count == 32 && s.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    /// V-02: `^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$`（3–63 文字・小文字英数とハイフン）
    public static func isValidBucketName(_ value: String) -> Bool {
        guard (3...63).contains(value.count) else { return false }
        guard let first = value.first, let last = value.last else { return false }
        let isAlnum: (Character) -> Bool = { ($0.isLowercase && $0.isLetter) || $0.isNumber }
        guard isAlnum(first), isAlnum(last) else { return false }
        return value.allSatisfy { isAlnum($0) || $0 == "-" }
    }

    /// V-03: `^[a-z0-9-]{1,32}$`
    public static func isValidAlias(_ value: String) -> Bool {
        guard (1...32).contains(value.count) else { return false }
        return value.allSatisfy { ($0.isLowercase && $0.isLetter) || $0.isNumber || $0 == "-" }
    }

    /// V-05: `https://` 始まり・末尾スラッシュなしに正規化
    public static func normalizePublicBaseURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    public static func isValidPublicBaseURL(_ value: String) -> Bool {
        let s = normalizePublicBaseURL(value)
        guard s.hasPrefix("https://"), let url = URL(string: s), url.host != nil else { return false }
        return true
    }

    /// SEC-05 / V-05: r2.dev はレート制限付きで本番非推奨
    public static func isR2DevDomain(_ value: String) -> Bool {
        guard let host = URL(string: normalizePublicBaseURL(value))?.host?.lowercased() else { return false }
        return host == "r2.dev" || host.hasSuffix(".r2.dev")
    }

    /// V-07 / E-11: 1 分〜168 時間（7 日）。
    ///
    /// **アプリ側で拒否しなければならない**（M-11）: rclone の S3 バックエンドは上限超過をエラーにせず、
    /// 黙って 7 日に切り詰める。切り詰めはログに出るだけで RC API の呼び出し側にはエラーが返らない。
    /// アプリが検証しないと、ユーザーは「8 日で発行できた」と誤認したまま 7 日で切れる URL を配ることになる。
    public static let maxExpireSeconds: Int = 7 * 24 * 3600
    public static let minExpireSeconds: Int = 60

    /// `"24h"` / `"7d"` / `"90m"` / `"3600s"` を秒に直す
    public static func parseExpire(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        guard let unit = s.last else { return nil }
        let multiplier: Int
        switch unit {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3600
        case "d": multiplier = 86400
        default:
            // 単位なしは秒とみなす
            return Int(s)
        }
        guard let value = Int(s.dropLast()) else { return nil }
        return value * multiplier
    }

    public static func isValidExpire(_ raw: String) -> Bool {
        guard let seconds = parseExpire(raw) else { return false }
        return (minExpireSeconds...maxExpireSeconds).contains(seconds)
    }

    /// V-08: 60 未満を拒否（Class A 課金の増大）
    public static func isValidDirCacheTime(_ seconds: Int) -> Bool { seconds >= 60 }

    // MARK: - プロファイル全体

    /// - Parameter otherProfiles: 他プロファイルの mountPath 重複を見るため（V-04）
    public static func validate(_ profile: Profile,
                                otherProfiles: [Profile] = [],
                                secretProvided: Bool,
                                home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [ValidationIssue] {
        var issues: [ValidationIssue] = []

        // displayName
        let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.count > 40 {
            issues.append(.init(rule: "V-00", field: "displayName",
                                message: "表示名は 1〜40 文字で入力してください。"))
        }

        // V-01
        if !isValidAccountId(profile.accountId) {
            issues.append(.init(rule: "V-01", field: "accountId",
                                message: "Account ID は 32 桁の英数字（0-9 / a-f）です。ダッシュボード右サイドからコピーしてください。"))
        }

        // V-09
        if !secretProvided {
            issues.append(.init(rule: "V-09", field: "secretAccessKey",
                                message: "Secret Access Key を入力してください。"))
        }

        if profile.buckets.isEmpty {
            issues.append(.init(rule: "V-03", field: "buckets",
                                message: "バケットを 1 つ以上登録してください。"))
        }

        var seenAliases = Set<String>()
        var seenPaths = Set<String>()
        // 他プロファイルの mountPath（V-04: プロファイル間でも重複禁止）
        var foreignPaths = Set<String>()
        for other in otherProfiles where other.id != profile.id {
            for b in other.buckets {
                foreignPaths.insert(canonical(b.resolvedMountPath(home: home)))
            }
        }

        for (index, bucket) in profile.buckets.enumerated() {
            let prefix = "buckets[\(index)]"

            // V-03
            if !isValidAlias(bucket.alias) {
                issues.append(.init(rule: "V-03", field: "\(prefix).alias",
                                    message: "別名は小文字英数とハイフン 1〜32 文字で入力してください。"))
            } else if !seenAliases.insert(bucket.alias).inserted {
                issues.append(.init(rule: "V-03", field: "\(prefix).alias",
                                    message: "別名「\(bucket.alias)」が重複しています。"))
            }

            // V-02
            if !isValidBucketName(bucket.bucketName) {
                issues.append(.init(rule: "V-02", field: "\(prefix).bucketName",
                                    message: "バケット名は小文字英数とハイフン 3〜63 文字で、先頭と末尾は英数字です。"))
            }

            // V-04
            let path = bucket.mountPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if !(path.hasPrefix("/") || path.hasPrefix("~/") || path == "~") {
                issues.append(.init(rule: "V-04", field: "\(prefix).mountPath",
                                    message: "マウント先は絶対パスまたは ~/ で始まるパスで指定してください。"))
            } else {
                let resolved = canonical(bucket.resolvedMountPath(home: home))
                if !seenPaths.insert(resolved).inserted {
                    issues.append(.init(rule: "V-04", field: "\(prefix).mountPath",
                                        message: "同じマウント先が重複しています。"))
                } else if foreignPaths.contains(resolved) {
                    issues.append(.init(rule: "V-04", field: "\(prefix).mountPath",
                                        message: "他のプロファイルが同じマウント先を使っています。"))
                }
                // 既存の非空ディレクトリを指してはならない（データ隠蔽の事故防止）
                if directoryIsNonEmpty(resolved) {
                    issues.append(.init(rule: "V-04", field: "\(prefix).mountPath",
                                        message: "\(resolved) には既にファイルがあります。空のフォルダを指定してください。"))
                }
            }

            // V-05 / V-06
            if bucket.visibility.isPublic {
                let base = bucket.publicBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                if base.isEmpty {
                    issues.append(.init(rule: "V-06", field: "\(prefix).publicBaseURL",
                                        message: "公開バケットには公開用ドメインが必要です。未設定のままだと公開 URL のコピーは使えません。"))
                } else if !isValidPublicBaseURL(base) {
                    issues.append(.init(rule: "V-05", field: "\(prefix).publicBaseURL",
                                        message: "公開用ドメインは https:// で始まる URL で入力してください。"))
                } else if isR2DevDomain(base) {
                    issues.append(.init(rule: "V-05", severity: .warning,
                                        field: "\(prefix).publicBaseURL",
                                        message: "*.r2.dev はレート制限があり本番利用は推奨されません。独自ドメインの接続を検討してください。"))
                }
            }
        }

        // V-07
        if !isValidExpire(profile.share.defaultExpire) {
            issues.append(.init(rule: "V-07", field: "share.defaultExpire",
                                message: "期限付きリンクは 1 分〜7 日の範囲で指定してください。7 日を超える共有は公開バケットの利用を検討してください。"))
        }

        // V-08
        if !isValidDirCacheTime(profile.advanced.dirCacheTimeSec) {
            issues.append(.init(rule: "V-08", field: "advanced.dirCacheTimeSec",
                                message: "ディレクトリキャッシュは 60 秒以上にしてください（短くすると R2 の Class A リクエスト料金が増えます）。"))
        }

        // advanced の許容範囲（§4.2）
        if !(5...50).contains(profile.advanced.vfsCacheMaxSizeGB) {
            issues.append(.init(rule: "V-10", field: "advanced.vfsCacheMaxSizeGB",
                                message: "キャッシュ上限は 5〜50 GB の範囲で指定してください。"))
        }
        if !(5...60).contains(profile.advanced.vfsWriteBackSec) {
            issues.append(.init(rule: "V-11", field: "advanced.vfsWriteBackSec",
                                message: "書き戻し間隔は 5〜60 秒の範囲で指定してください。"))
        }
        if !(4...16).contains(profile.advanced.transfers) {
            issues.append(.init(rule: "V-12", field: "advanced.transfers",
                                message: "並列転送数は 4〜16 の範囲で指定してください。"))
        }

        return issues
    }

    public static func hasBlockingErrors(_ issues: [ValidationIssue]) -> Bool {
        issues.contains { $0.severity == .error }
    }

    // MARK: - 補助

    /// V-03b: 既定の mountPath を組み立てる。
    public static func defaultMountPath(profile: Profile, alias: String) -> String {
        let slug = Slug.profileSlug(displayName: profile.displayName, profileId: profile.id)
        return "~/\(AppIdentity.productName)/\(slug)/\(alias)"
    }

    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func directoryIsNonEmpty(_ path: String) -> Bool {
        // マウント済みかどうかを**先に**、ファイルシステムに触れずに判定する。
        // 詰まったマウント（サーバが死んだ NFS）の上では
        // `fileExists` も `contentsOfDirectory` も永久に返らないため、
        // 入力検証がそのまま UI のハングになる。
        if SystemMountTable.isMountedAccordingToTable(path) {
            // すでにマウント済みなら「非空」でも事故にはならない（再マウントの経路）
            return false
        }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        guard isDirectory.boolValue else { return true }
        let contents = (try? fm.contentsOfDirectory(atPath: path)) ?? []
        return !contents.filter { $0 != ".DS_Store" }.isEmpty
    }
}
