import Foundation

public enum ProfileStoreError: Error, LocalizedError, Sendable {
    case unsupportedSchemaVersion(found: Int, supported: Int)
    case decodeFailed(String)
    case profileNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchemaVersion(let found, let supported):
            return "設定ファイルの形式（v\(found)）がこのバージョンのアプリ（v\(supported)）より新しいため読めません。"
        case .decodeFailed(let detail):
            return "設定ファイルを読めませんでした: \(detail)"
        case .profileNotFound(let id):
            return "プロファイル \(id) が見つかりません。"
        }
    }
}

/// §04: 接続プロファイルの CRUD。
///
/// 非機密フィールドを JSON（0600）に永続化する。
/// Access Key ID / Secret Access Key は持たない — それは `KeychainStore` の担当（§4.1）。
///
/// §8.6.3: 書き込みは常に**全体を書き直す**（追記しない）。
/// 一時ファイル + `rename(2)` の原子的置換なので、途中でクラッシュしても壊れた JSON が残らない。
public final class ProfileStore: @unchecked Sendable {

    private let fileURL: URL
    private let keychain: KeychainStore
    private let lock = NSLock()

    public init(fileURL: URL, keychain: KeychainStore = KeychainStore()) {
        self.fileURL = fileURL
        self.keychain = keychain
    }

    public convenience init(paths: AppPaths = AppPaths(), keychain: KeychainStore = KeychainStore()) {
        self.init(fileURL: paths.profilesJSON, keychain: keychain)
    }

    // MARK: - 読み書き

    /// §8.1 手順 1: 読込・スキーマバージョン検証。
    /// ファイルが無い場合は空のドキュメントを返す（初回起動）。
    public func load() throws -> ProfilesDocument {
        lock.lock(); defer { lock.unlock() }
        return try loadUnlocked()
    }

    private func loadUnlocked() throws -> ProfilesDocument {
        guard let data = try? Data(contentsOf: fileURL) else {
            return ProfilesDocument()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let document: ProfilesDocument
        do {
            document = try decoder.decode(ProfilesDocument.self, from: data)
        } catch {
            throw ProfileStoreError.decodeFailed(error.localizedDescription)
        }
        guard document.schemaVersion <= ProfilesDocument.currentSchemaVersion else {
            throw ProfileStoreError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                supported: ProfilesDocument.currentSchemaVersion)
        }
        return document
    }

    private func saveUnlocked(_ document: ProfilesDocument) throws {
        var normalized = document
        normalized.schemaVersion = ProfilesDocument.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AtomicFileWriter.write(try encoder.encode(normalized), to: fileURL, mode: 0o600)
    }

    public func save(_ document: ProfilesDocument) throws {
        lock.lock(); defer { lock.unlock() }
        try saveUnlocked(document)
    }

    // MARK: - §8.6.3 冪等な更新

    /// プロファイルを追加または更新する。同じ内容で 2 回呼んでも結果は同じ。
    ///
    /// - Parameter credentials: 渡された場合のみ Keychain を更新する（`SecItemUpdate` → 無ければ `Add`）。
    ///   nil なら既存の認証情報をそのまま残す。
    @discardableResult
    public func upsert(_ profile: Profile,
                       credentials: R2Credentials? = nil,
                       makeActive: Bool = false) throws -> ProfilesDocument {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()

        if let index = document.profiles.firstIndex(where: { $0.id == profile.id }) {
            document.profiles[index] = profile
        } else {
            document.profiles.append(profile)
        }
        if makeActive || document.activeProfileId.isEmpty {
            document.activeProfileId = profile.id
        }

        if let credentials {
            try keychain.store(credentials, for: profile)
        }
        try saveUnlocked(document)
        return document
    }

    /// §8.6.3 / SEC-G07: プロファイル削除。
    ///
    /// - Keychain 項目も同時に削除する。2 回目は `errSecItemNotFound` になるが成功として扱う。
    /// - 削除対象が `activeProfileId` だった場合、残ったプロファイルの**先頭**を新しい active にする。
    ///   1 つも残らない場合は空にしてオンボーディングへ戻す
    ///   （起動時に §8.1 手順 2 が失敗して停止するのを避けるため）。
    @discardableResult
    public func delete(profileId: String) throws -> ProfilesDocument {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()

        document.profiles.removeAll { $0.id == profileId }
        if document.activeProfileId == profileId {
            document.activeProfileId = document.profiles.first?.id ?? ""
        }

        // 存在しない項目の削除は成功扱い（冪等）
        try keychain.deleteCredentials(for: profileId)
        try saveUnlocked(document)
        return document
    }

    @discardableResult
    public func setActive(profileId: String) throws -> ProfilesDocument {
        lock.lock(); defer { lock.unlock() }
        var document = try loadUnlocked()
        guard document.profiles.contains(where: { $0.id == profileId }) else {
            throw ProfileStoreError.profileNotFound(profileId)
        }
        document.activeProfileId = profileId
        try saveUnlocked(document)
        return document
    }

    // MARK: - 補助

    public func activeProfile() throws -> Profile? {
        try load().activeProfile
    }

    /// §8.1 手順 2: Keychain から activeProfile の認証情報を取得する。
    public func credentials(for profile: Profile) throws -> R2Credentials {
        try keychain.credentials(for: profile)
    }

    public func hasCredentials(for profile: Profile) -> Bool {
        keychain.hasCredentials(for: profile)
    }

    /// SEC-G08: エクスポートには認証情報を含めない。
    public func exportSanitized() throws -> Data {
        let document = try load()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document)
    }
}
