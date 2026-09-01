import Foundation

/// §4.2 プロファイル スキーマ。
///
/// Access Key ID / Secret Access Key はここに持たない（Keychain・§4.1）。
/// すべて値型で、更新は「新しいコピーを返す」形にする。
public enum BucketVisibility: String, Codable, Sendable, CaseIterable {
    case privateBucket = "private"
    case publicBucket = "public"

    public var isPublic: Bool { self == .publicBucket }
}

public struct BucketConfig: Codable, Sendable, Equatable, Identifiable {
    /// マウントパスの末尾要素になる。[a-z0-9-]{1,32}・プロファイル内で一意（V-03）
    public var alias: String
    /// R2 上の実バケット名。[a-z0-9-]{3,63}（V-02）
    public var bucketName: String
    public var visibility: BucketVisibility
    /// ユーザーが設定した希望値。`~` を含みうる。永続化されるのはこちらだけ（§6.2 RULE）
    public var mountPath: String
    public var autoMount: Bool
    /// visibility == .publicBucket のときのみ有効・必須（V-06）
    public var publicBaseURL: String

    public var id: String { alias }

    public init(alias: String,
                bucketName: String,
                visibility: BucketVisibility,
                mountPath: String,
                autoMount: Bool = true,
                publicBaseURL: String = "") {
        self.alias = alias
        self.bucketName = bucketName
        self.visibility = visibility
        self.mountPath = mountPath
        self.autoMount = autoMount
        self.publicBaseURL = publicBaseURL
    }

    /// G-08: read-only は visibility から自動導出する。独立フィールドとして持たない（設定の二重管理を避ける）。
    /// 覆せるのは advanced.allowDirectWriteToPublic のみ。
    public func isReadOnly(allowDirectWriteToPublic: Bool) -> Bool {
        visibility.isPublic && !allowDirectWriteToPublic
    }

    /// `~` を展開した絶対パス。mount/mount に送る値（§6.2 RULE）。
    public func resolvedMountPath(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        Self.expandTilde(mountPath, home: home)
    }

    public static func expandTilde(
        _ path: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2))).path
        }
        return path
    }
}

public struct ShareSettings: Codable, Sendable, Equatable {
    /// presigned の既定期限。上限 168h(7d)
    public var defaultExpire: String
    /// SEC-G03（MUST）。**常に true**。
    ///
    /// 「OFF にできるのは共有ダイアログでの都度操作のみで、永続的なオプトアウト設定を提供しない」
    /// という規定を、**永続化された値を読まない**ことで構造的に守る。
    /// 設定画面にトグルは無く、profiles.json を手で書き換えても（あるいは古い版が書いた false が
    /// 残っていても）読み込み時に true へ戻る。
    /// 除去しない選択は共有ダイアログの `stripMetadata` 引数でのみ行う。
    public let stripImageMetadata: Bool = true
    /// DD-001 §4.4 準拠
    public var publicKeyTemplate: String
    public var defaultPrefix: String
    /// true で max-age=31536000, immutable を付与（U-04 が G1-9 ⑤ で確認できるまで既定 false）
    public var immutableCacheControl: Bool

    public init(defaultExpire: String = "24h",
                publicKeyTemplate: String = "{prefix}/{yyyy}/{slug}.{ext}",
                defaultPrefix: String = "assets",
                immutableCacheControl: Bool = false) {
        self.defaultExpire = defaultExpire
        self.publicKeyTemplate = publicKeyTemplate
        self.defaultPrefix = defaultPrefix
        self.immutableCacheControl = immutableCacheControl
    }
}

/// §4.2 advanced。既定では UI 非表示。DD-001 §6.5 の許容範囲に一致。
public struct AdvancedSettings: Codable, Sendable, Equatable {
    /// G-03。mount/types の応答から選択
    public var mountType: String
    /// G-08。既定 false = public は read-only
    public var allowDirectWriteToPublic: Bool
    /// 固定。UI で変更不可（D-05 継承）
    public var vfsCacheMode: String
    /// 許容 5–50
    public var vfsCacheMaxSizeGB: Int
    /// 許容 5–60
    public var vfsWriteBackSec: Int
    /// 許容 4–16
    public var transfers: Int
    /// 許容 60–300。60 未満は禁止（V-08 / DD-001 §10 コスト制約）
    public var dirCacheTimeSec: Int
    public var vfsReadChunkSizeMB: Int
    public var s3ChunkSizeMB: Int
    public var s3UploadCutoffMB: Int
    /// K-04 継承
    public var excludes: [String]

    public init(mountType: String = "nfsmount",
                allowDirectWriteToPublic: Bool = false,
                vfsCacheMode: String = "full",
                vfsCacheMaxSizeGB: Int = 10,
                vfsWriteBackSec: Int = 15,
                transfers: Int = 8,
                dirCacheTimeSec: Int = 60,
                vfsReadChunkSizeMB: Int = 16,
                s3ChunkSizeMB: Int = 64,
                s3UploadCutoffMB: Int = 128,
                excludes: [String] = [".DS_Store", "._*", ".Spotlight-V100/**", ".Trashes/**"]) {
        self.mountType = mountType
        self.allowDirectWriteToPublic = allowDirectWriteToPublic
        self.vfsCacheMode = vfsCacheMode
        self.vfsCacheMaxSizeGB = vfsCacheMaxSizeGB
        self.vfsWriteBackSec = vfsWriteBackSec
        self.transfers = transfers
        self.dirCacheTimeSec = dirCacheTimeSec
        self.vfsReadChunkSizeMB = vfsReadChunkSizeMB
        self.s3ChunkSizeMB = s3ChunkSizeMB
        self.s3UploadCutoffMB = s3UploadCutoffMB
        self.excludes = excludes
    }
}

public struct Profile: Codable, Sendable, Equatable, Identifiable {
    /// ULID。生成後不変。Keychain の account キーを兼ねる。
    public let id: String
    /// UI 表示名。1–40 文字。日本語を含みうる。
    public var displayName: String
    /// 32 桁 hex（V-01）。endpoint 組み立てに使用。
    public var accountId: String
    /// 空なら https://{accountId}.r2.cloudflarestorage.com
    public var endpoint: String
    public var buckets: [BucketConfig]
    public var share: ShareSettings
    public var advanced: AdvancedSettings
    /// SEC-04: 365 日を超えたらローテーション推奨バナーを出す
    public var credentialCreatedAt: Date?

    public init(id: String = ULID.generate(),
                displayName: String,
                accountId: String,
                endpoint: String = "",
                buckets: [BucketConfig] = [],
                share: ShareSettings = ShareSettings(),
                advanced: AdvancedSettings = AdvancedSettings(),
                credentialCreatedAt: Date? = nil) {
        self.id = id
        self.displayName = displayName
        self.accountId = accountId
        self.endpoint = endpoint
        self.buckets = buckets
        self.share = share
        self.advanced = advanced
        self.credentialCreatedAt = credentialCreatedAt
    }

    /// endpoint が空なら accountId から組み立てる。
    public var resolvedEndpoint: String {
        let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return "https://\(accountId).r2.cloudflarestorage.com"
    }

    /// SEC-04: 認証情報が古いか
    public func credentialsAreStale(now: Date = Date(), thresholdDays: Int = 365) -> Bool {
        guard let created = credentialCreatedAt else { return false }
        return now.timeIntervalSince(created) > Double(thresholdDays) * 86400
    }

    public func bucket(alias: String) -> BucketConfig? {
        buckets.first { $0.alias == alias }
    }

    /// Keychain の account キー（§4.1: 2 値を 1 項目に詰めない）
    public var accessKeyIdAccount: String { "\(id).accessKeyId" }
    public var secretAccessKeyAccount: String { "\(id).secretAccessKey" }
}

/// profiles.json のルート
public struct ProfilesDocument: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var activeProfileId: String
    public var profiles: [Profile]

    public init(schemaVersion: Int = ProfilesDocument.currentSchemaVersion,
                activeProfileId: String = "",
                profiles: [Profile] = []) {
        self.schemaVersion = schemaVersion
        self.activeProfileId = activeProfileId
        self.profiles = profiles
    }

    public var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileId }
    }
}
