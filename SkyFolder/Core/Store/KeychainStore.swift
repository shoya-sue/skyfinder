import Foundation
import Security

public enum KeychainError: Error, LocalizedError, Sendable, Equatable {
    /// E-08: Keychain 読み取り失敗
    case readFailed(OSStatus)
    case writeFailed(OSStatus)
    case deleteFailed(OSStatus)
    case notFound

    public var errorDescription: String? {
        switch self {
        case .readFailed, .notFound:
            return "保存された認証情報を読み取れませんでした。Secret Access Key を再入力してください。"
        case .writeFailed(let s):
            return "認証情報を保存できませんでした（\(s)）。"
        case .deleteFailed(let s):
            return "認証情報を削除できませんでした（\(s)）。"
        }
    }

    public var catalogID: String { "E-08" }
}

/// §4.1 / SEC-G06: 認証情報の Keychain 保存。
///
/// - service は bundle identifier と同一（§15.1・変更不可）
/// - **2 値を 1 項目に詰めない**。account を分けて 2 項目として保存する。
///   1 項目に JSON で詰めると、Access Key ID を読むだけの場面でも Secret を復号することになる。
///
/// ## SEC-G06 (a) の現状（M-24・実測）
///
/// 「アクセス可能条件は `kSecAttrAccessibleWhenUnlocked`（画面ロック中は読めない）」という規定は、
/// **`kSecUseDataProtectionKeychain: true` を付けたときにしか成立しない**。
/// 付けないと macOS はファイルベースの login.keychain へ書き、
/// そちらは `kSecAttrAccessible` を**解釈しない**（data protection keychain 専用の属性）。
/// 属性を書いているのに効かない、という気づきにくい形で破れる。
///
/// ところが `kSecUseDataProtectionKeychain` は **application-identifier entitlement を要求する**。
/// これには Team ID が要り、**ad-hoc 署名では付与できない**。
/// 実測: 署名済み `.app`（ad-hoc + Hardened Runtime）で `SecItemAdd` が
/// `errSecMissingEntitlement (-34018)` を返し、**認証情報を一切保存できなくなった**。
///
/// したがって本実装は、
/// **使えるなら data protection keychain、駄目なら legacy へ落ちる**。
/// 落ちたことは `activeMode` で外から分かるようにし、診断画面に表示する
/// — 黙って落ちると SEC-G06 (a) が満たされていない事実が見えなくなる。
///
/// **Developer ID 署名では data protection が使えるはずなので、G5-2 で再確認すること。**
public struct KeychainStore: Sendable {
    public let service: String

    /// どちらの keychain を使っているか。
    public enum Mode: String, Sendable {
        /// `kSecAttrAccessibleWhenUnlocked` が効く。SEC-G06 (a) が成立する。
        case dataProtection
        /// login.keychain。`kSecAttrAccessible` は無視される（画面ロック中も読める）。
        case legacy
        case undetermined

        public var satisfiesLockProtection: Bool { self == .dataProtection }
    }

    /// 実際に書き込みが通ったモード。まだ書いていなければ `.undetermined`。
    public static let modeBox = ModeBox()

    public final class ModeBox: @unchecked Sendable {
        private var value: Mode = .undetermined
        private let lock = NSLock()
        public var mode: Mode { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ m: Mode) { lock.lock(); value = m; lock.unlock() }
    }

    public var activeMode: Mode { Self.modeBox.mode }

    public init(service: String = AppIdentity.keychainService) {
        self.service = service
    }

    private func baseQuery(account: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    /// 使えるほうのモードを試す順序。まだ確定していなければ data protection を先に試す。
    private var modesToTry: [Mode] {
        switch activeMode {
        case .dataProtection: return [.dataProtection]
        case .legacy: return [.legacy]
        case .undetermined: return [.dataProtection, .legacy]
        }
    }

    // MARK: - 読み書き

    public func read(account: String) throws -> String {
        var lastStatus: OSStatus = errSecItemNotFound
        for mode in modesToTry {
            var query = baseQuery(account: account, dataProtection: mode == .dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let text = String(data: data, encoding: .utf8) {
                Self.modeBox.set(mode)
                return text
            }
            lastStatus = status
        }
        if lastStatus == errSecItemNotFound { throw KeychainError.notFound }
        throw KeychainError.readFailed(lastStatus)
    }

    /// §8.6.3: `SecItemUpdate` → 無ければ `SecItemAdd` の順。
    /// Add を先に呼ぶと既存項目で `errSecDuplicateItem` になる。
    public func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        var lastStatus: OSStatus = errSecSuccess
        for mode in modesToTry {
            let query = baseQuery(account: account, dataProtection: mode == .dataProtection)

            let updateStatus = SecItemUpdate(query as CFDictionary,
                                             [kSecValueData as String: data] as CFDictionary)
            if updateStatus == errSecSuccess { Self.modeBox.set(mode); return }
            if updateStatus != errSecItemNotFound { lastStatus = updateStatus; continue }

            var addQuery = query
            addQuery[kSecValueData as String] = data
            // SEC-G06 (a): 画面ロック中は読めない。
            // **data protection keychain でのみ効く**（legacy では無視される）。
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { Self.modeBox.set(mode); return }
            lastStatus = addStatus
        }
        throw KeychainError.writeFailed(lastStatus)
    }

    /// §8.6.3 / SEC-G07: 2 回目の削除では `errSecItemNotFound` が返る。
    /// これは成功として扱う — 目的は「その項目が存在しない状態」であり、すでにそうなら達成されている。
    public func delete(account: String) throws {
        // 両方のモードから消す（過去のモードで書いた項目を残さない）
        var lastStatus: OSStatus = errSecItemNotFound
        for mode in [Mode.dataProtection, .legacy] {
            let status = SecItemDelete(
                baseQuery(account: account, dataProtection: mode == .dataProtection) as CFDictionary)
            if status == errSecSuccess { return }
            if status != errSecItemNotFound { lastStatus = status }
        }
        if lastStatus == errSecItemNotFound || lastStatus == errSecSuccess { return }
        // entitlement が無くて data protection 側が -34018 を返すのは想定内なので成功扱い
        if lastStatus == errSecMissingEntitlement { return }
        throw KeychainError.deleteFailed(lastStatus)
    }

    public func exists(account: String) -> Bool {
        for mode in modesToTry {
            var query = baseQuery(account: account, dataProtection: mode == .dataProtection)
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess { return true }
        }
        return false
    }

    // MARK: - プロファイル単位の操作

    public func credentials(for profile: Profile) throws -> R2Credentials {
        R2Credentials(accessKeyId: try read(account: profile.accessKeyIdAccount),
                      secretAccessKey: try read(account: profile.secretAccessKeyAccount))
    }

    public func store(_ credentials: R2Credentials, for profile: Profile) throws {
        try write(credentials.accessKeyId, account: profile.accessKeyIdAccount)
        try write(credentials.secretAccessKey, account: profile.secretAccessKeyAccount)
    }

    /// SEC-G07: プロファイル削除時に Keychain 項目も同時に削除する。孤児の認証情報を残さない。
    public func deleteCredentials(for profileId: String) throws {
        try delete(account: "\(profileId).accessKeyId")
        try delete(account: "\(profileId).secretAccessKey")
    }

    /// V-09: 保存後は再表示せず「設定済み」とだけ表示する。その判定に使う。
    public func hasCredentials(for profile: Profile) -> Bool {
        exists(account: profile.accessKeyIdAccount) && exists(account: profile.secretAccessKeyAccount)
    }
}
