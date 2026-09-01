import Foundation
import Testing
@testable import SkyFolderKit

@Suite("原子的な書き込み（§8.6.3）", .serialized)
struct AtomicFileWriterTests {

    @Test("書き込み後の権限が指定どおりになる")
    func setsPermissions() throws {
        let dir = TestSupport.makeTemporaryDirectory("atomic")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("a.json")

        try AtomicFileWriter.write(Data("{}".utf8), to: file, mode: 0o600)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test("既存ファイルを置き換えても一時ファイルが残らない")
    func leavesNoTemporaryFile() throws {
        let dir = TestSupport.makeTemporaryDirectory("atomic")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("a.json")

        try AtomicFileWriter.write(Data("{\"v\":1}".utf8), to: file)
        try AtomicFileWriter.write(Data("{\"v\":2}".utf8), to: file)

        #expect(try String(contentsOf: file, encoding: .utf8) == "{\"v\":2}")
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents == ["a.json"], "\(contents)")
    }
}

/// Keychain を実際に触るテスト。テスト用の service を使い、本番の項目に影響しない。
@Suite("Keychain（§4.1 / SEC-G06 / SEC-G07）", .serialized)
struct KeychainStoreTests {

    private let store = KeychainStore(service: "dev.fracturelab.skyfolder.tests")
    private let account = "test.\(UUID().uuidString)"

    @Test("保存 → 読み出し → 削除")
    func roundTrip() throws {
        try store.write("value-1", account: account)
        #expect(try store.read(account: account) == "value-1")
        try store.delete(account: account)
        #expect(!store.exists(account: account))
    }

    /// T-G37: 2 回連続で保存しても項目が重複せず 1 組のまま。
    /// `SecItemUpdate` → 無ければ `SecItemAdd` の順（Add を先に呼ぶと重複エラーになる）。
    @Test("T-G37: 二重保存で重複しない")
    func writeIsIdempotent() throws {
        defer { try? store.delete(account: account) }
        try store.write("value-1", account: account)
        try store.write("value-2", account: account)
        #expect(try store.read(account: account) == "value-2")
    }

    /// T-G38 / §8.6.3: 2 回目の削除では `errSecItemNotFound` が返るが、これは成功として扱う。
    @Test("T-G38: 二重削除でエラーにならない")
    func deleteIsIdempotent() throws {
        try store.write("value", account: account)
        try store.delete(account: account)
        try store.delete(account: account)   // 例外を投げないこと
        #expect(!store.exists(account: account))
    }

    /// §4.1: 2 値を 1 項目に詰めず、account を分けて 2 項目として保存する
    @Test("Access Key と Secret を別項目に保存する")
    func separatesCredentials() throws {
        let profile = TestSupport.sampleProfile(id: "prof_\(UUID().uuidString)")
        defer { try? store.deleteCredentials(for: profile.id) }

        try store.store(R2Credentials(accessKeyId: "AK", secretAccessKey: "SK"), for: profile)
        #expect(profile.accessKeyIdAccount != profile.secretAccessKeyAccount)
        #expect(try store.read(account: profile.accessKeyIdAccount) == "AK")
        #expect(try store.read(account: profile.secretAccessKeyAccount) == "SK")

        let credentials = try store.credentials(for: profile)
        #expect(credentials.accessKeyId == "AK")
        #expect(credentials.secretAccessKey == "SK")
    }

    /// SEC-G07: プロファイル削除時に Keychain 項目も同時に削除する
    @Test("T-G11: プロファイル削除で認証情報も消える")
    func deletesCredentialsWithProfile() throws {
        let profile = TestSupport.sampleProfile(id: "prof_\(UUID().uuidString)")
        try store.store(R2Credentials(accessKeyId: "AK", secretAccessKey: "SK"), for: profile)
        #expect(store.hasCredentials(for: profile))

        try store.deleteCredentials(for: profile.id)
        #expect(!store.hasCredentials(for: profile))
    }
}

@Suite("プロファイルの保存（§4.1 / §8.6.3）", .serialized)
struct ProfileStoreTests {

    private func makeStore() -> (ProfileStore, URL) {
        let dir = TestSupport.makeTemporaryDirectory("profiles")
        let file = dir.appendingPathComponent("profiles.json")
        let keychain = KeychainStore(service: "dev.fracturelab.skyfolder.tests.\(UUID().uuidString)")
        return (ProfileStore(fileURL: file, keychain: keychain), dir)
    }

    @Test("ファイルが無ければ空のドキュメントを返す")
    func loadsEmptyDocument() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let document = try store.load()
        #expect(document.profiles.isEmpty)
        #expect(document.activeProfileId.isEmpty)
        #expect(document.schemaVersion == ProfilesDocument.currentSchemaVersion)
    }

    @Test("保存したプロファイルを読み戻せる")
    func roundTrip() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let profile = TestSupport.sampleProfile()
        _ = try store.upsert(profile, makeActive: true)

        let document = try store.load()
        #expect(document.profiles.count == 1)
        #expect(document.activeProfileId == profile.id)
        #expect(document.activeProfile?.buckets.count == 2)
    }

    /// T-G37: 2 回連続で保存しても profiles.json が壊れず、重複もしない
    @Test("T-G37: 二重保存で重複しない")
    func upsertIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let profile = TestSupport.sampleProfile()
        _ = try store.upsert(profile, makeActive: true)
        _ = try store.upsert(profile, makeActive: true)

        let document = try store.load()
        #expect(document.profiles.count == 1)
    }

    /// T-G38 / §8.6.3: 2 回目の削除でエラーにならない
    @Test("T-G38: 二重削除でエラーにならない")
    func deleteIsIdempotent() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let profile = TestSupport.sampleProfile()
        _ = try store.upsert(profile, makeActive: true)
        _ = try store.delete(profileId: profile.id)
        let document = try store.delete(profileId: profile.id)
        #expect(document.profiles.isEmpty)
    }

    /// §8.6.3: 削除対象が active だった場合、残ったプロファイルの**先頭**を新しい active にする
    @Test("T-G38: active を削除したら残りの先頭が active になる")
    func reassignsActiveOnDelete() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let first = TestSupport.sampleProfile(id: "prof_A")
        var second = TestSupport.sampleProfile(id: "prof_B")
        second.displayName = "second"
        second.buckets = [BucketConfig(alias: "b", bucketName: "bucket-two",
                                       visibility: .privateBucket, mountPath: "~/x/b")]

        _ = try store.upsert(first, makeActive: true)
        _ = try store.upsert(second)
        #expect(try store.load().activeProfileId == "prof_A")

        let document = try store.delete(profileId: "prof_A")
        #expect(document.activeProfileId == "prof_B")
    }

    /// 1 つも残らない場合は activeProfileId を空にしてオンボーディングへ戻す
    @Test("T-G38: 最後の 1 つを削除したら active は空になる")
    func clearsActiveWhenEmpty() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let profile = TestSupport.sampleProfile()
        _ = try store.upsert(profile, makeActive: true)
        let document = try store.delete(profileId: profile.id)
        #expect(document.activeProfileId.isEmpty)
    }

    @Test("profiles.json は 0600 で書かれる")
    func fileIsPrivate() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        _ = try store.upsert(TestSupport.sampleProfile(), makeActive: true)
        let file = dir.appendingPathComponent("profiles.json")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    /// SEC-02: secret がディスク上に平文で存在する瞬間が無い
    @Test("profiles.json に認証情報を書かない")
    func neverWritesCredentials() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        _ = try store.upsert(TestSupport.sampleProfile(),
                             credentials: R2Credentials(accessKeyId: "AKIA_LEAK_CHECK",
                                                        secretAccessKey: "SECRET_LEAK_CHECK"),
                             makeActive: true)
        let text = try String(contentsOf: dir.appendingPathComponent("profiles.json"),
                              encoding: .utf8)
        #expect(!text.contains("AKIA_LEAK_CHECK"))
        #expect(!text.contains("SECRET_LEAK_CHECK"))
    }

    @Test("将来のスキーマバージョンを拒否する")
    func rejectsNewerSchema() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("profiles.json")
        try AtomicFileWriter.write(
            Data(#"{"schemaVersion":99,"activeProfileId":"","profiles":[]}"#.utf8), to: file)
        #expect(throws: ProfileStoreError.self) { _ = try store.load() }
    }

    /// SEC-G08: エクスポートに認証情報を含めない
    @Test("SEC-G08: エクスポートに認証情報を含めない")
    func exportExcludesCredentials() throws {
        let (store, dir) = makeStore()
        defer { TestSupport.remove(dir) }
        _ = try store.upsert(TestSupport.sampleProfile(),
                             credentials: R2Credentials(accessKeyId: "AKIA_EXPORT",
                                                        secretAccessKey: "SECRET_EXPORT"),
                             makeActive: true)
        let text = String(data: try store.exportSanitized(), encoding: .utf8) ?? ""
        #expect(!text.contains("AKIA_EXPORT"))
        #expect(!text.contains("SECRET_EXPORT"))
    }
}

@Suite("共有履歴（SEC-G05）", .serialized)
struct ShareHistoryTests {

    /// **記録するのは key・発行時刻・期限の 3 つのみ。URL 文字列は保存しない。**
    /// 保存すると、失効前の署名付き URL がディスク上に残り再配布経路になる。
    @Test("SEC-G05: URL を保存しない")
    func neverStoresURL() throws {
        let dir = TestSupport.makeTemporaryDirectory("history")
        defer { TestSupport.remove(dir) }
        let file = dir.appendingPathComponent("share-history.json")
        let store = ShareHistoryStore(fileURL: file)

        store.append(ShareHistoryEntry(bucketName: "b", key: "assets/a.png",
                                       issuedAt: Date(), expiresAt: Date().addingTimeInterval(3600)))

        let text = try String(contentsOf: file, encoding: .utf8)
        // key・発行時刻・期限は記録される
        #expect(store.load().first?.key == "assets/a.png")
        // URL は一切残らない
        #expect(!text.lowercased().contains("x-amz"))
        #expect(!text.contains("://"))
        // 型として url を持たないこと（Mirror で構造を確認する）
        let mirror = Mirror(reflecting: ShareHistoryEntry(bucketName: "b", key: "k",
                                                          issuedAt: Date(), expiresAt: Date()))
        #expect(!mirror.children.contains { $0.label == "url" })
    }

    @Test("直近 50 件だけを残す")
    func limitsTo50() {
        let dir = TestSupport.makeTemporaryDirectory("history")
        defer { TestSupport.remove(dir) }
        let store = ShareHistoryStore(fileURL: dir.appendingPathComponent("h.json"))
        for i in 0..<60 {
            store.append(ShareHistoryEntry(bucketName: "b", key: "k\(i)",
                                           issuedAt: Date(), expiresAt: Date()))
        }
        let entries = store.load()
        #expect(entries.count == ShareHistoryStore.limit)
        #expect(entries.first?.key == "k59")
    }

    @Test("期限切れを判定できる")
    func detectsExpiry() {
        let now = Date()
        let entry = ShareHistoryEntry(bucketName: "b", key: "k", issuedAt: now,
                                      expiresAt: now.addingTimeInterval(60))
        #expect(!entry.isExpired(now: now))
        #expect(entry.isExpired(now: now.addingTimeInterval(61)))
    }
}
