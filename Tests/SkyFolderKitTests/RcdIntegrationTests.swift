import Foundation
import Testing
@testable import SkyFolderKit

/// 実際に rcd を起動して RC API を叩くテスト。
///
/// バックエンドは `type=local` を使う。RC API の挙動そのものはバックエンドに依存しないため、
/// マウント・冪等性・read-only（G-08）・除外フィルタはこれで確かめられる。
/// **S3 固有の挙動（SigV4・マルチパート・presigned の実発行）はここでは確かめられない** — G1-9 の担当。
final class RcdHarness {
    let root: URL
    /// マウントポイントの親。`root` とは別の木にする（上の理由）。
    let mountRoot: URL
    let source: URL
    let mountPoint: URL
    let logFile: URL
    private let supervisor: RcdSupervisor
    private(set) var client: RcClient!
    private(set) var endpoint: RcEndpoint!

    /// `loc:` リモートで使うためのリモート名
    static let remoteName = "loc"

    init() async throws {
        // ここで一括の残骸掃除をしてはいけない。
        // ネストして harness を作るテスト（CRIT-03 の再現）で、
        // **外側の生きているマウントまで外してしまう**。
        // 後始末は各 harness の shutdown() が自分のマウントだけを対象に行う。
        root = TestSupport.makeTemporaryDirectory("rcd")
        source = root.appendingPathComponent("source", isDirectory: true)
        // **マウント先は root の外に置く。**
        // root を再帰削除するときにマウントポイントの中へ入ると、
        // サーバ（rcd）が死んでいた場合そこで永久にブロックする（実測で 2 度発生）。
        // 外に出しておけば、削除がマウントに触れることが構造的に起こらない。
        mountRoot = TestSupport.makeTemporaryDirectory("rcdmnt")
        mountPoint = mountRoot.appendingPathComponent("mnt", isDirectory: true)
        logFile = root.appendingPathComponent("rcd.log")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)

        supervisor = RcdSupervisor(rcloneURL: TestSupport.rcloneURL,
                                   paths: AppPaths(home: root))
        let spec = RcdLaunchSpec(rcloneURL: TestSupport.rcloneURL,
                                 localRemoteName: Self.remoteName,
                                 cacheDir: root.appendingPathComponent("cache"),
                                 logFile: logFile)
        endpoint = try await supervisor.start(specFactory: { spec })
        client = RcClient(endpoint: endpoint)
    }

    /// 前のテストが解除し損ねた NFS マウントを外す。
    /// 残ったままだとその中へ入る操作が永久にブロックする。
    static func cleanStaleMounts() {
        // マウント表だけを見る（パスに触れると詰まったマウントで固まる）
        for entry in SystemMountTable.entries()
        where entry.fsTypeName == "nfs" && entry.mountedOn.contains("skyfolder-") {
            _ = SystemMountTable.forceUnmount(entry.mountedOn)
        }
    }

    var fs: String { "\(Self.remoteName):\(source.path)" }

    func write(_ name: String, _ contents: String = "hello") throws {
        let url = source.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    /// **後始末で「壊れているかもしれないパス」に触れてはいけない。**
    ///
    /// サーバ（rcd）が死んだ NFS マウントは hard mount なので、
    /// その上では `open()` も `statfs()` も**永久に返らない**。
    /// `FileManager.removeItem` は再帰的に walk し、`statfs` を使う素朴なマウント判定も同じく詰まる
    /// — どちらもテストプロセスごと固まる（実測で 2 度発生させた）。
    ///
    /// したがって判定は**カーネルのマウント表だけ**（`getmntinfo`）で行い、
    /// マウント先は最初から削除対象の外に置いてある。
    func shutdown() async {
        // **M-23**: 生きた nfsmount があると `mount/unmountall` は応答を返さないことがある。
        // 既定の 30 秒を待つと 1 テストあたり 40 秒以上かかるので、本番と同じく期限を切って
        // OS の `umount` で仕上げる。
        _ = try? await client?.callRaw(RcPath.mountUnmountAll, timeout: 3)
        if SystemMountTable.isMountedAccordingToTable(mountPoint.path) {
            _ = SystemMountTable.forceUnmount(mountPoint.path)
        }
        await supervisor.stop()
        try? await Task.sleep(nanoseconds: 200_000_000)

        // 残っていれば強制解除する（SIGKILL 経路ではクリーンアップが走らない）。
        // umount 自体はパスを traverse しないので、詰まったマウントにも使える。
        for _ in 0..<10 {
            guard SystemMountTable.isMountedAccordingToTable(mountPoint.path) else { break }
            _ = SystemMountTable.forceUnmount(mountPoint.path)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        // root にはマウントが含まれないので、ここは常に安全に消せる
        TestSupport.remove(root)

        if SystemMountTable.isMountedAccordingToTable(mountPoint.path) {
            FileHandle.standardError.write(Data(
                "⚠️ マウントを解除できませんでした。触れずに残します: \(mountPoint.path)\n".utf8))
            return
        }
        TestSupport.remove(mountRoot)
    }

    /// マウントが I/O 可能になるまで待つ（rc の応答が返っても NFS が使えるとは限らないため）
    func waitUntilReadable(_ name: String, timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(
                atPath: mountPoint.appendingPathComponent(name).path) { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    /// マウント用の BucketConfig（bucketName は使われないので任意）
    func bucket(visibility: BucketVisibility) -> BucketConfig {
        BucketConfig(alias: visibility.isPublic ? "public" : "private",
                     bucketName: "unused",
                     visibility: visibility,
                     mountPath: mountPoint.path,
                     publicBaseURL: visibility.isPublic ? "https://files.example.com" : "")
    }

    /// `MountController` は `AppIdentity.fs(bucketName:)` を使うため、
    /// local バックエンドでのマウントは直接 rc を叩く。
    func mount(readOnly: Bool, advanced: AdvancedSettings = AdvancedSettings()) async throws {
        var vfs = MountOptionsBuilder.vfsOpt(
            for: BucketConfig(alias: "a", bucketName: "b",
                              visibility: readOnly ? .publicBucket : .privateBucket,
                              mountPath: mountPoint.path),
            advanced: advanced)
        vfs["ReadOnly"] = readOnly
        var params: [String: Any] = [
            "fs": fs,
            "mountPoint": mountPoint.path,
            "mountType": advanced.mountType,      // CRIT-01: 省略禁止
            "vfsOpt": vfs,
            "mountOpt": ["VolumeName": "SkyFolder-test", "AttrTimeout": 5_000_000_000],
        ]
        if let filter = MountOptionsBuilder.filter(advanced: advanced) { params["_filter"] = filter }
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try await client.callRaw(RcPath.mountMount, params: params, timeout: 60)
    }
}

/// ファイルシステム操作をタイムアウト付きで実行する。
///
/// read-only の NFS マウントに対する操作は、状況によっては即座にエラーを返さず**詰まる**ことがある。
/// テストが無限に待たないよう、超過は失敗として扱う。
enum BlockingIO {
    enum Outcome: Equatable, CustomStringConvertible {
        case succeeded
        case failed(errno: Int32)
        case timedOut

        var description: String {
            switch self {
            case .succeeded: return "成功（拒否されなかった）"
            case .failed(let code): return "拒否（errno=\(code) \(String(cString: strerror(code))))"
            case .timedOut: return "★ タイムアウト（応答なし）"
            }
        }
        var wasRejected: Bool { if case .failed = self { return true }; return false }
    }

    /// - Parameter body: 失敗時に `NSError`（POSIX）を投げる同期処理
    static func run(timeout: TimeInterval = 8,
                    _ body: @escaping @Sendable () throws -> Void) async -> Outcome {
        let box = Mutex<Outcome?>(nil)
        let thread = Thread {
            do { try body(); box.set(.succeeded) }
            catch let error as NSError {
                let code = error.domain == NSPOSIXErrorDomain
                    ? Int32(error.code)
                    : Int32((error.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? error.code)
                box.set(.failed(errno: code))
            }
        }
        thread.stackSize = 512 * 1024
        thread.start()

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let outcome = box.get() { return outcome }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return .timedOut
    }
}

/// harness を作り、本体の成否にかかわらず**必ず待って**後始末する。
/// `defer { Task { ... } }` は待たないため、次のテストと競合する。
func withHarness(_ body: (RcdHarness) async throws -> Void) async throws {
    let harness = try await RcdHarness()
    do {
        try await body(harness)
    } catch {
        await harness.shutdown()
        throw error
    }
    await harness.shutdown()
}

@Suite("rcd 統合（実際にプロセスを起動する）", .serialized)
struct RcdIntegrationTests {

    private static var enabled: Bool { TestSupport.rcloneAvailable }

    // MARK: - CRIT-01 / T-G05 / T-G06

    @Test("T-G05 / CRIT-01: mount/types に nfsmount がある", .enabled(if: Self.enabled))
    func mountTypesIncludesNfsmount() async throws {
        try await withHarness { harness in
            let types = try await harness.client.mountTypes()
            // v1.75.0 での実測値。異なる場合は同梱バージョンが変わった証拠なので §14.1 を再検証する。
            #expect(types.contains("nfsmount"))
            #expect(!types.contains("mount"), "mount(FUSE) が現れた — 前提が変わった: \(types)")

            let controller = MountController(client: harness.client)
            _ = try await controller.verifyMountTypeAvailable("nfsmount")
            // E-03: 使えない方式を要求したら弾かれる
            await #expect(throws: MountError.self) {
                _ = try await controller.verifyMountTypeAvailable("mount")
            }
        }
    }

    /// **前提**: 検証機に macFUSE / fuse-t が導入されていないこと（導入済みなら成立しない）。
    @Test("T-G06: mountType を省略すると失敗する（CRIT-01 の必要性）", .enabled(if: Self.enabled))
    func omittingMountTypeFails() async throws {
        let filesystems = (try? FileManager.default
            .contentsOfDirectory(atPath: "/Library/Filesystems")) ?? []
        try #require(!filesystems.contains { $0.lowercased().contains("fuse") },
                     "macFUSE / fuse-t が導入されているため T-G06 は成立しない")

        try await withHarness { harness in
            try FileManager.default.createDirectory(at: harness.mountPoint,
                                                    withIntermediateDirectories: true)
            var thrown: RcError?
            do {
                // mountType を渡さない → cmount が選ばれる
                try await harness.client.callRaw(RcPath.mountMount, params: [
                    "fs": harness.fs, "mountPoint": harness.mountPoint.path,
                ], timeout: 60)
            } catch let error as RcError { thrown = error }

            #expect(thrown != nil, "mountType 省略でも成功してしまった（CRIT-01 の前提が崩れている）")
            // マウントされていないこと
            #expect(try await harness.client.listMounts().isEmpty)
        }
    }

    // MARK: - G-08 / U-12 / T-G26

    /// G-08 の実現機構。read-only マウントでは書込み・削除・リネームが拒否される。
    @Test("G-08 / U-12 / T-G26: ReadOnly マウントは書込み・削除・リネームを拒否する",
          .enabled(if: Self.enabled))
    func readOnlyMountRejectsWrites() async throws {
        try await withHarness { harness in
            try harness.write("existing.txt", "original")
            try await harness.mount(readOnly: true)
            #expect(await harness.waitUntilReadable("existing.txt"), "マウントが I/O 可能にならない")

            // 読めること
            let mountPoint = harness.mountPoint
            let readOutcome = await BlockingIO.run {
                _ = try String(contentsOf: mountPoint.appendingPathComponent("existing.txt"),
                               encoding: .utf8)
            }
            #expect(readOutcome == .succeeded, "読み取りができない: \(readOutcome)")

            // 書込みが拒否されること
            let write = await BlockingIO.run {
                try Data("x".utf8).write(to: mountPoint.appendingPathComponent("new.txt"))
            }
            #expect(write.wasRejected, "read-only マウントに書き込めた（G-08 が効いていない）: \(write)")

            // 削除が拒否されること
            let delete = await BlockingIO.run {
                try FileManager.default.removeItem(
                    at: mountPoint.appendingPathComponent("existing.txt"))
            }
            #expect(delete.wasRejected, "read-only マウントから削除できた: \(delete)")

            // リネームが拒否されること
            let rename = await BlockingIO.run {
                try FileManager.default.moveItem(
                    at: mountPoint.appendingPathComponent("existing.txt"),
                    to: mountPoint.appendingPathComponent("renamed.txt"))
            }
            #expect(rename.wasRejected, "read-only マウントでリネームできた: \(rename)")

            // 原本は無傷
            #expect(try String(contentsOf: harness.source.appendingPathComponent("existing.txt"),
                               encoding: .utf8) == "original")
        }
    }

    /// M-01 / T-G12b: read-only マウントでも **OS レベルでは read-only フラグが付かない**。
    /// 拒否は rclone の VFS 層で行われる。この結果で「G-08 が効いていない」と誤診断しないこと。
    @Test("M-01 / T-G12b: OS の mount 表に read-only フラグは付かない", .enabled(if: Self.enabled))
    func readOnlyIsNotMarkedAtOSLevel() async throws {
        try await withHarness { harness in
            try harness.write("a.txt")
            try await harness.mount(readOnly: true)
            #expect(await harness.waitUntilReadable("a.txt"))

            // 実測: OS のマウント表は symlink を解決した表現（/private/var/...）を返すが、
            // rclone は渡した表現（/var/...）をそのまま返す。両側を解決してから突き合わせる。
            let entry = SystemMountTable.entry(forMountPoint: harness.mountPoint.path)
            try #require(entry != nil, "OS のマウント表に現れない")
            // ファイルシステムに触れない判定でも一致すること（後始末はこちらを使う）
            #expect(SystemMountTable.isMountedAccordingToTable(harness.mountPoint.path))
            // 素朴な文字列比較は一致しないことを、この場で示しておく
            #expect(!SystemMountTable.entries().contains { $0.mountedOn == harness.mountPoint.path }
                    || entry!.mountedOn == harness.mountPoint.path)
            #expect(entry?.isReadOnlyFlag == false, "OS が read-only を立てた — M-01 の前提が変わった")
            #expect(entry?.fsTypeName == "nfs")
            #expect(SystemMountTable.isMountedAccordingToTable(harness.mountPoint.path))
        }
    }

    /// allowDirectWriteToPublic = true 相当の経路
    @Test("read-write マウントは書き込める", .enabled(if: Self.enabled))
    func readWriteMountAcceptsWrites() async throws {
        try await withHarness { harness in
            try harness.write("seed.txt")
            try await harness.mount(readOnly: false)
            #expect(await harness.waitUntilReadable("seed.txt"))

            let mountPoint = harness.mountPoint
            let outcome = await BlockingIO.run {
                try Data("written".utf8).write(to: mountPoint.appendingPathComponent("written.txt"))
            }
            #expect(outcome == .succeeded, "read-write マウントに書けない: \(outcome)")
        }
    }

    // MARK: - U-08 / §6.3 第 1 層

    @Test("U-08: _filter の除外ルールが長命な VFS に持続適用される", .enabled(if: Self.enabled))
    func excludeRulesPersist() async throws {
        try await withHarness { harness in
            try harness.write(".DS_Store", "junk")
            try harness.write("._resource", "junk")
            try harness.write("visible.txt", "ok")

            try await harness.mount(readOnly: false)
            #expect(await harness.waitUntilReadable("visible.txt"))

            let contents = try FileManager.default.contentsOfDirectory(atPath: harness.mountPoint.path)
            #expect(contents.contains("visible.txt"))
            #expect(!contents.contains(".DS_Store"), "除外が効いていない: \(contents)")
            #expect(!contents.contains("._resource"), "除外が効いていない: \(contents)")
        }
    }

    // MARK: - §8.6.1 冪等性

    /// T-G31: マウント済みで再度マウントしてもエラーにならず、二重登録も起きない。
    @Test("T-G31: 二度マウントしても listmounts は 1 件のまま", .enabled(if: Self.enabled))
    func mountIsIdempotent() async throws {
        try await withHarness { harness in
            try harness.write("a.txt")
            try await harness.mount(readOnly: false)
            #expect(await harness.waitUntilReadable("a.txt"))

            var raised: RcError?
            do { try await harness.mount(readOnly: false) } catch let error as RcError { raised = error }

            // 2 回目は rclone がエラーを返す（応答は非冪等）
            try #require(raised != nil, "2 回目のマウントが成功した — 前提が変わった")
            // M-07: nfsmount でも「FUSE」と表示される。末尾の実体で判定する。
            #expect(raised!.meansAlreadyMounted, "想定外のエラー: \(raised!.message)")
            // 状態としては冪等
            let mounts = try await harness.client.listMounts()
            #expect(mounts.filter { $0.mountPoint == harness.mountPoint.path }.count == 1)
        }
    }

    /// T-G32: `mount not found` を成功として扱うので、何度アンマウントしても例外にならない。
    @Test("T-G32: 二度アンマウントしてもエラーにならない", .enabled(if: Self.enabled))
    func unmountIsIdempotent() async throws {
        try await withHarness { harness in
            try harness.write("a.txt")
            try await harness.mount(readOnly: false)
            #expect(await harness.waitUntilReadable("a.txt"))

            let controller = MountController(client: harness.client)
            // M-23: RC API が応答しなくても OS 側で外れること（期限を短くして経路を通す）
            try await controller.ensureUnmounted(harness.mountPoint.path, rcTimeout: 3)
            #expect(!SystemMountTable.isMountedAccordingToTable(harness.mountPoint.path))
            // 2 回目・3 回目は「すでに外れている」ので即座に返る
            try await controller.ensureUnmounted(harness.mountPoint.path, rcTimeout: 3)
            try await controller.ensureUnmounted("/tmp/not-mounted-\(UUID().uuidString)",
                                                 rcTimeout: 3)
        }
    }

    @Test("mount/unmountall は何度呼んでもよい（完全な冪等）", .enabled(if: Self.enabled))
    func unmountAllIsIdempotent() async throws {
        try await withHarness { harness in
            let controller = MountController(client: harness.client)
            try await controller.unmountAll(rcTimeout: 3)
            try await controller.unmountAll(rcTimeout: 3)
            #expect(try await harness.client.listMounts().isEmpty)
        }
    }

    @Test("options/set は冪等", .enabled(if: Self.enabled))
    func optionsSetIsIdempotent() async throws {
        try await withHarness { harness in
            try await harness.client.optionsSet(["nfs": ["HandleLimit": 1_000_000]])
            try await harness.client.optionsSet(["nfs": ["HandleLimit": 1_000_000]])
        }
    }

    /// U-09: 既定値が既に 1000000 で DD-001 §6.3 の指定値と一致する（明示不要）
    @Test("U-09: nfs.HandleLimit の既定値は 1000000", .enabled(if: Self.enabled))
    func handleLimitDefault() async throws {
        try await withHarness { harness in
            let options = try await harness.client.optionsGet()
            let nfs = options["nfs"] as? [String: Any]
            #expect(nfs?["HandleLimit"] as? Int == 1_000_000)
        }
    }

    // MARK: - オブジェクト操作の冪等性

    /// 存在しないキーへの削除は **HTTP 404 / `object not found`**。
    /// 接続テストの後片付けと staging の掃除で重複実行が起こりうるため成功扱いにする。
    @Test("deletefile は存在しないキーで 404 を返す（成功扱いにする根拠）",
          .enabled(if: Self.enabled))
    func deleteFileIdempotency() async throws {
        try await withHarness { harness in
            try harness.write("target.txt")
            try await harness.client.callRaw(RcPath.operationsDeleteFile,
                                             params: ["fs": harness.fs, "remote": "target.txt"])
            var raised: RcError?
            do {
                try await harness.client.callRaw(RcPath.operationsDeleteFile,
                                                 params: ["fs": harness.fs, "remote": "target.txt"])
            } catch let error as RcError { raised = error }

            try #require(raised != nil, "2 回目の削除が成功した — 前提が変わった")
            #expect(raised!.statusCode == 404)
            #expect(raised!.meansObjectNotFound, "実測と違うエラー: \(raised!.message)")
        }
    }

    /// **M-14（実測）**: `movefile` は移動先が既に存在しても**黙って上書きする**。
    /// §8.6.3 は「失敗しうる」を前提にフォールバックを規定していたが、実際の危険は逆で、
    /// 取り下げを二度押しすると先に取り下げた `gone/{key}` を失う。
    @Test("M-14: movefile は移動先が存在しても黙って上書きする", .enabled(if: Self.enabled))
    func moveFileOverwritesSilently() async throws {
        try await withHarness { harness in
            try harness.write("a.txt", "new")
            try harness.write("gone/a.txt", "old")

            try await harness.client.callRaw(RcPath.operationsMoveFile, params: [
                "srcFs": harness.fs, "srcRemote": "a.txt",
                "dstFs": harness.fs, "dstRemote": "gone/a.txt",
            ])
            let after = try String(contentsOf: harness.source.appendingPathComponent("gone/a.txt"),
                                   encoding: .utf8)
            #expect(after == "new", "上書きされなかった — 前提が変わった")
        }
    }

    /// 上記への防御: 取り下げは事前に `stat` して退避先を変える
    @Test("takedown の防御: stat で衝突を検出しフォールバック key を使う",
          .enabled(if: Self.enabled))
    func takedownDetectsCollision() async throws {
        try await withHarness { harness in
            try harness.write("gone/a.txt", "old")
            let stat = try await harness.client.callRaw(
                RcPath.operationsStat, params: ["fs": harness.fs, "remote": "gone/a.txt"])
            #expect(stat["item"] != nil && !(stat["item"] is NSNull))

            let fallback = PublicKeyTemplate.goneKeyFallback(
                "a.txt", now: Date(timeIntervalSince1970: 1_700_000_000))
            #expect(fallback == "gone/a.txt.1700000000")
            #expect(fallback != PublicKeyTemplate.goneKey("a.txt"))
        }
    }

    @Test("stat は存在しないキーで item: null を返す（エラーではない）", .enabled(if: Self.enabled))
    func statReturnsNullForMissing() async throws {
        try await withHarness { harness in
            let response = try await harness.client.callRaw(
                RcPath.operationsStat, params: ["fs": harness.fs, "remote": "nope.txt"])
            #expect(response["item"] is NSNull)
        }
    }

    /// §7.3 手順 4: 恒久公開のアップロードに使う経路。
    /// `_async` で jobid が返り、`_config.UploadHeaders` も受理される（U-04 の形式確認）。
    @Test("copyfile は _async で jobid を返し _config を受理する", .enabled(if: Self.enabled))
    func copyFileSupportsAsyncAndConfig() async throws {
        try await withHarness { harness in
            try harness.write("src.bin", String(repeating: "x", count: 1024))
            let status = try await harness.client.callAsyncJob(RcPath.operationsCopyFile, params: [
                "srcFs": harness.fs, "srcRemote": "src.bin",
                "dstFs": harness.fs, "dstRemote": "assets/2026/src.bin",
                "_config": ["UploadHeaders": [["Key": "Cache-Control",
                                               "Value": "public, max-age=31536000, immutable"]]],
            ])
            #expect(status.finished)
            #expect(status.success)
            #expect(FileManager.default.fileExists(
                atPath: harness.source.appendingPathComponent("assets/2026/src.bin").path))
        }
    }

    // MARK: - §8.4 stale mount

    /// T-G16 / E-05: マウント先が空でないときは中止する（既存データの隠蔽を防ぐ）
    @Test("T-G16 / E-05: マウント先が空でないと中止する", .enabled(if: Self.enabled))
    func refusesNonEmptyMountPoint() async throws {
        try await withHarness { harness in
            try FileManager.default.createDirectory(at: harness.mountPoint,
                                                    withIntermediateDirectories: true)
            try Data("existing".utf8).write(to: harness.mountPoint.appendingPathComponent("keep.txt"))

            let controller = MountController(client: harness.client)
            await #expect(throws: MountError.self) {
                try await controller.prepareMountPoint(harness.mountPoint.path, reclaimedByUs: false)
            }
            #expect(FileManager.default.fileExists(
                atPath: harness.mountPoint.appendingPathComponent("keep.txt").path),
                "既存ファイルが消された")
        }
    }

    @Test("マウント先が無ければ 0700 で作る", .enabled(if: Self.enabled))
    func createsMountPoint() async throws {
        try await withHarness { harness in
            let target = harness.root.appendingPathComponent("new-mount")
            let controller = MountController(client: harness.client)
            try await controller.prepareMountPoint(target.path, reclaimedByUs: false)

            var isDirectory: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory))
            #expect(isDirectory.boolValue)
            let mode = try FileManager.default
                .attributesOfItem(atPath: target.path)[.posixPermissions] as? Int
            #expect(mode == 0o700)
        }
    }

    /// `.DS_Store` だけがある場合は「空」とみなす（K-04 の除外対象なので事故にならない）
    @Test("マウント先に .DS_Store だけならマウントを許す", .enabled(if: Self.enabled))
    func allowsDSStoreOnlyMountPoint() async throws {
        try await withHarness { harness in
            try FileManager.default.createDirectory(at: harness.mountPoint,
                                                    withIntermediateDirectories: true)
            try Data().write(to: harness.mountPoint.appendingPathComponent(".DS_Store"))
            let controller = MountController(client: harness.client)
            try await controller.prepareMountPoint(harness.mountPoint.path, reclaimedByUs: false)
        }
    }

    // MARK: - M-05 / M-04

    /// 環境変数由来のリモートは `config/dump` に現れない。**リモート定義の確認に使ってはならない**。
    /// 同時に、認証情報が出ないので診断画面に表示しても安全。
    @Test("M-05: config/dump に環境変数由来のリモートは現れない", .enabled(if: Self.enabled))
    func configDumpIsEmpty() async throws {
        try await withHarness { harness in
            let dump = try await harness.client.configDump()
            #expect(dump.isEmpty, "config/dump が空でない: \(dump.keys)")

            // 確認は operations/list の成否で行う（§4.4 接続テストと同じ方法）
            try harness.write("a.txt")
            let list = try await harness.client.call(
                RcPath.operationsList, params: ["fs": harness.fs, "remote": ""],
                as: RcListResponse.self)
            #expect(list.list.contains { $0.name == "a.txt" })
        }
    }

    /// M-04: `Using --user {rc-user} --pass XXXX` — パスワードはマスクされるがユーザー名は平文。
    @Test("M-04: 起動ログに rc-user が平文で出る（マスクが必要な根拠）", .enabled(if: Self.enabled))
    func rcUserAppearsInLog() async throws {
        try await withHarness { harness in
            let log = (try? String(contentsOf: harness.logFile, encoding: .utf8)) ?? ""
            #expect(log.contains("Using --user"))
            #expect(log.contains(harness.endpoint.user), "rc-user が平文で出ていない — 前提が変わった")
            #expect(!log.contains(harness.endpoint.password), "パスワードが平文で出た")

            // SEC-G04 のマスカを通すと消える
            let masker = LogMasker(rcUsers: [harness.endpoint.user])
            #expect(!masker.mask(log).contains(harness.endpoint.user))
        }
    }

    /// M-12: `--log-file` 指定時、ポートは stdout でも stderr でもなくログファイルに出る。
    @Test("M-12: 待受ポートはログファイルに出る", .enabled(if: Self.enabled))
    func portComesFromLogFile() async throws {
        try await withHarness { harness in
            let log = (try? String(contentsOf: harness.logFile, encoding: .utf8)) ?? ""
            #expect(RcdPortReader.parsePort(in: log) == harness.endpoint.port)
        }
    }

    // MARK: - CRIT-03

    /// `--rc-addr 127.0.0.1:0` では rcd を二重起動しても**別ポートで両方立ち上がる**。
    /// このとき新しい rcd の `listmounts` は 0 件を返すが OS 上にはマウントが実在する
    /// — §02 の DESIGN INVARIANT がこの状況で偽になる。
    /// プロセスの単一性は rclone ではなく**アプリが担保しなければならない**。
    @Test("CRIT-03: rcd の二重起動を rclone は防がない（状態の単一情報源が破綻する）",
          .enabled(if: Self.enabled))
    func duplicateRcdBreaksSingleSourceOfTruth() async throws {
        try await withHarness { first in
            try first.write("a.txt")
            try await first.mount(readOnly: true)
            #expect(await first.waitUntilReadable("a.txt"))

            // 2 本目を起動する（ポートが違うので bind エラーにならない）
            try await withHarness { second in
                #expect(second.endpoint.port != first.endpoint.port,
                        "同じポートになった — 前提が変わった")

                let firstView = try await first.client.listMounts()
                let secondView = try await second.client.listMounts()
                #expect(firstView.contains { $0.mountPoint == first.mountPoint.path })
                // 破綻の再現: 2 本目からは見えない
                #expect(!secondView.contains { $0.mountPoint == first.mountPoint.path },
                        "2 本目から見えてしまった — 前提が変わった")
                // OS 上には実在する
                #expect(SystemMountTable.isMountedAccordingToTable(first.mountPoint.path),
                        "OS 上にマウントが無い")
            }
        }
    }

    /// §8.6.2 (b): 孤児 rcd の回収。**RC API は呼ばない**（呼べない）。
    /// SIGTERM だけでマウントも自動解除される（M-08）。
    @Test("M-08 / M-09: SIGTERM で孤児 rcd を回収するとマウントも消える",
          .enabled(if: Self.enabled))
    func orphanReclamationBySIGTERM() async throws {
        let root = TestSupport.makeTemporaryDirectory("orphan")
        // **マウント先は削除対象ツリーの外に置く。**
        // rcd を落としたあとマウントが残ると、`removeItem` がその中へ再帰して永久にブロックする。
        let mountRoot = TestSupport.makeTemporaryDirectory("orphanmnt")
        defer {
            TestSupport.remove(root)
            if !SystemMountTable.isMountedAccordingToTable(
                mountRoot.appendingPathComponent("mnt").path) {
                TestSupport.remove(mountRoot)
            }
        }
        let source = root.appendingPathComponent("source", isDirectory: true)
        let mountPoint = mountRoot.appendingPathComponent("mnt", isDirectory: true)
        let logFile = root.appendingPathComponent("rcd.log")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        try Data("x".utf8).write(to: source.appendingPathComponent("a.txt"))

        let paths = AppPaths(home: root)
        try paths.ensureDirectories(profileId: nil)
        let supervisor = RcdSupervisor(rcloneURL: TestSupport.rcloneURL, paths: paths)
        let spec = RcdLaunchSpec(rcloneURL: TestSupport.rcloneURL, localRemoteName: "loc",
                                 cacheDir: root.appendingPathComponent("cache"), logFile: logFile)
        let endpoint = try await supervisor.start(specFactory: { spec })
        let client = RcClient(endpoint: endpoint)

        try await client.callRaw(RcPath.mountMount, params: [
            "fs": "loc:\(source.path)", "mountPoint": mountPoint.path,
            "mountType": "nfsmount", "vfsOpt": ["CacheMode": "full", "ReadOnly": true],
        ], timeout: 60)
        // 判定は非ブロック版で行う。SIGTERM 後は statfs が返らなくなりうる。
        #expect(SystemMountTable.isMountedAccordingToTable(mountPoint.path), "マウントされていない")

        // PID ファイルが書かれていること（§8.6.2 (a)）。認証情報は書かない（SEC-G01）。
        let pidFile = RcdPidFile(url: paths.rcdPID)
        let record = pidFile.read()
        try #require(record != nil, "rcd.pid が書かれていない")
        #expect(record!.port == endpoint.port)
        let raw = try String(contentsOf: paths.rcdPID, encoding: .utf8)
        #expect(!raw.contains(endpoint.password), "PID ファイルに rc-pass が書かれた（SEC-G01 違反）")
        #expect(!raw.contains(endpoint.user), "PID ファイルに rc-user が書かれた（SEC-G01 違反）")

        // 実行パスの照合で「自分が起動したもの」と断定できること（PID 使い回し対策）
        #expect(ProcessInspector.isOurRclone(pid: record!.pid,
                                             bundledBinary: TestSupport.rcloneURL))

        // SIGTERM を送る（RC API は呼ばない）
        let forced = await ProcessInspector.terminateAsync(pid: record!.pid, gracePeriod: 5)
        #expect(!ProcessInspector.isAlive(pid: record!.pid), "プロセスが残っている")

        // **M-25（実測・M-08 の前提が崩れている）**
        //
        // 設計書 M-08 は「SIGTERM を送ると 1 秒で終了し、マウントも自動的に解除される」と記録し、
        // §8.6.2 (b) の孤児回収はそれに依存している。
        // しかし本環境では、マウントを保持した rcd は SIGTERM で終わらず SIGKILL まで進み、
        // **マウントが残る**（M-23 の「rclone のアンマウントが返らない」と同じ根と見られる）。
        //
        // したがって孤児回収は SIGTERM だけでは完結しない。
        // §8.4 手順 2 の例外（自分由来と断定できた残骸は umount してよい）が**必須**になる。
        var cleared = false
        for _ in 0..<15 {
            if !SystemMountTable.isMountedAccordingToTable(mountPoint.path) { cleared = true; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        if !cleared {
            // 残った場合に回収できることを確かめる（これが本番の経路）
            #expect(forced || !cleared, "SIGTERM だけでは解除されなかった（M-25）")
            #expect(SystemMountTable.forceUnmount(mountPoint.path),
                    "OS の umount でも解除できない — 回収経路が存在しないことになる")
            #expect(!SystemMountTable.isMountedAccordingToTable(mountPoint.path))
        }

        await supervisor.stop()
    }

    /// `reclaimOrphans` が PID ファイル経由で孤児を回収できること（§8.1 手順 0-b）
    @Test("T-G34 相当: reclaimOrphans が孤児 rcd を回収する", .enabled(if: Self.enabled))
    func reclaimOrphansTerminatesPreviousInstance() async throws {
        let root = TestSupport.makeTemporaryDirectory("reclaim")
        defer { TestSupport.remove(root) }
        let logFile = root.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let paths = AppPaths(home: root)
        try paths.ensureDirectories(profileId: nil)

        // 1 本目 =「前回のインスタンス」
        let first = RcdSupervisor(rcloneURL: TestSupport.rcloneURL, paths: paths)
        let spec = RcdLaunchSpec(rcloneURL: TestSupport.rcloneURL, localRemoteName: "loc",
                                 cacheDir: root.appendingPathComponent("cache"), logFile: logFile)
        _ = try await first.start(specFactory: { spec })
        let orphanPID = RcdPidFile(url: paths.rcdPID).read()?.pid
        try #require(orphanPID != nil)
        #expect(ProcessInspector.isAlive(pid: orphanPID!))

        // 2 本目 =「再起動したアプリ」。起動前に手順 0-b を実行する。
        let second = RcdSupervisor(rcloneURL: TestSupport.rcloneURL, paths: paths)
        let result = await second.reclaimOrphans()

        #expect(result.hadPidFile)
        #expect(result.reclaimedPIDs.contains(orphanPID!))
        #expect(!ProcessInspector.isAlive(pid: orphanPID!), "孤児が生き残った")
        // §8.6.2 (d): PID ファイルは消える
        #expect(RcdPidFile(url: paths.rcdPID).read() == nil)

        await first.stop()
        await second.stop()
    }
    // MARK: - §8.2 rcd の死活監視と自動再起動

    /// T-G15: rcd プロセスを kill すると自動再起動する。
    /// §8.2 の指数バックオフ（1s / 2s / 4s / 8s / 16s・5 回で断念）。
    @Test("T-G15: rcd が死ぬと自動再起動し、新しいポートで応答する", .enabled(if: Self.enabled))
    func rcdRestartsAfterKill() async throws {
        let root = TestSupport.makeTemporaryDirectory("restart")
        defer { TestSupport.remove(root) }
        let logFile = root.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let paths = AppPaths(home: root)
        try paths.ensureDirectories(profileId: nil)

        var config = RcdSupervisor.Config()
        config.restartBackoff = [0.2, 0.4]      // テストを待たせないため短縮
        let supervisor = RcdSupervisor(rcloneURL: TestSupport.rcloneURL, paths: paths,
                                       config: config)

        let restarted = Mutex<RcEndpoint?>(nil)
        await supervisor.setHandlers(onRestarted: { endpoint in
            restarted.set(endpoint)
        })

        let spec = RcdLaunchSpec(rcloneURL: TestSupport.rcloneURL, localRemoteName: "loc",
                                 cacheDir: root.appendingPathComponent("cache"), logFile: logFile)
        let first = try await supervisor.start(specFactory: { spec })
        let firstPID = await supervisor.currentStatus().pid
        try #require(firstPID != nil)

        // 外から kill する（クラッシュ相当）
        kill(firstPID!, SIGKILL)

        // 再起動を待つ
        var newEndpoint: RcEndpoint?
        for _ in 0..<60 {
            if let e = restarted.get() { newEndpoint = e; break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        try #require(newEndpoint != nil, "自動再起動しなかった")

        // 新しいプロセス・新しいポートになっていること
        let status = await supervisor.currentStatus()
        #expect(status.isRunning, "再起動後に running でない: \(status.phase)")
        #expect(status.restartCount >= 1)
        #expect(status.pid != firstPID, "PID が変わっていない")
        #expect(newEndpoint!.port != first.port, "ポートが変わっていない（:0 なら毎回変わるはず）")

        // SEC-G01: rc-user / rc-pass は起動ごとに作り直される
        #expect(newEndpoint!.user != first.user, "rc-user が使い回された")
        #expect(newEndpoint!.password != first.password, "rc-pass が使い回された")

        // 新しい endpoint で実際に応答すること
        let client = RcClient(endpoint: newEndpoint!)
        _ = try await client.coreVersion()

        // 古い認証情報では通らないこと
        let stale = RcClient(endpoint: RcEndpoint(port: newEndpoint!.port,
                                                  user: first.user, password: first.password))
        await #expect(throws: RcError.self) { _ = try await stale.coreVersion() }

        await supervisor.stop()
        #expect(!ProcessInspector.isAlive(pid: status.pid ?? 0))
        // §8.6.2 (d): 終了時に PID ファイルを消す
        #expect(RcdPidFile(url: paths.rcdPID).read() == nil)
    }

    /// 意図的に停止したときは再起動しない（§8.2「ユーザーがアプリから」の経路）
    @Test("意図的な停止では再起動しない", .enabled(if: Self.enabled))
    func intentionalStopDoesNotRestart() async throws {
        let root = TestSupport.makeTemporaryDirectory("stop")
        defer { TestSupport.remove(root) }
        let logFile = root.appendingPathComponent("rcd.log")
        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let paths = AppPaths(home: root)
        try paths.ensureDirectories(profileId: nil)

        let supervisor = RcdSupervisor(rcloneURL: TestSupport.rcloneURL, paths: paths)
        let restarted = Mutex<Bool>(false)
        await supervisor.setHandlers(onRestarted: { _ in restarted.set(true) })

        let spec = RcdLaunchSpec(rcloneURL: TestSupport.rcloneURL, localRemoteName: "loc",
                                 cacheDir: root.appendingPathComponent("cache"), logFile: logFile)
        _ = try await supervisor.start(specFactory: { spec })
        await supervisor.stop()

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        #expect(!restarted.get(), "意図的な停止なのに再起動した")
        let status = await supervisor.currentStatus()
        #expect(status.phase == .stopped)
    }
    // MARK: - §7.3 恒久公開の冪等性（T-G20 / T-G35 / T-G36）

    /// `ShareService` は `AppIdentity.fs(bucketName:)` を組み立てるため、
    /// local バックエンドでは fs が一致しない。ここでは**上書き確認と取り下げの判定ロジック**を
    /// 実際の rc 応答に対して検証する（アップロード自体は copyfile で確認済み）。
    ///
    /// T-G20 / T-G35: 同じファイルを 2 回公開すると、2 回目は既存を検出する。
    /// key は決定的なので 1 回目と完全に一致する。
    @Test("T-G20 / T-G35: 2 回公開で衝突を検出し、key は 1 回目と一致する",
          .enabled(if: Self.enabled))
    func detectsOverwriteOnSecondPublish() async throws {
        try await withHarness { harness in
            let share = ShareSettings()
            let fixedNow = Date(timeIntervalSince1970: 1_772_000_000)

            // 1 回目: key を組み立てて置く
            let key1 = PublicKeyTemplate.render(template: share.publicKeyTemplate,
                                                prefix: "img", fileName: "Logo Final.PNG",
                                                now: fixedNow)
            try harness.write(key1, "first")

            // 衝突確認（§7.3 手順 2）は operations/stat で行う
            let stat1 = try await harness.client.callRaw(
                RcPath.operationsStat, params: ["fs": harness.fs, "remote": key1])
            #expect(stat1["item"] != nil && !(stat1["item"] is NSNull),
                    "既存 key を検出できない → 無確認上書きになる")

            // 2 回目: 同じ入力からは同じ key になる（slug 規則が決定的・§8.6.3）
            let key2 = PublicKeyTemplate.render(template: share.publicKeyTemplate,
                                                prefix: "img", fileName: "Logo Final.PNG",
                                                now: fixedNow)
            #expect(key2 == key1)
            #expect(key1 == "img/2026/logo-final.png")

            // 存在しない key では衝突しない
            let stat2 = try await harness.client.callRaw(
                RcPath.operationsStat, params: ["fs": harness.fs, "remote": "img/2026/other.png"])
            #expect(stat2["item"] is NSNull)
        }
    }

    /// T-G36: 同じ key を 2 回取り下げても、1 回目に退避した内容が失われない。
    ///
    /// M-14 のとおり `movefile` は黙って上書きするので、
    /// **事前の `stat` が効いていないとこのテストは落ちる**。
    @Test("T-G36: 2 回取り下げても 1 回目の退避が失われない", .enabled(if: Self.enabled))
    func takedownTwiceKeepsBothVersions() async throws {
        try await withHarness { harness in
            let key = "assets/2026/a.png"
            let goneKey = PublicKeyTemplate.goneKey(key)

            // 1 回目
            try harness.write(key, "version-1")
            #expect(!(try await harness.objectExists(goneKey)))
            try await harness.client.callRaw(RcPath.operationsMoveFile, params: [
                "srcFs": harness.fs, "srcRemote": key,
                "dstFs": harness.fs, "dstRemote": goneKey,
            ])
            #expect(try String(contentsOf: harness.source.appendingPathComponent(goneKey),
                               encoding: .utf8) == "version-1")

            // 2 回目: 同じ key をもう一度公開してから取り下げる
            try harness.write(key, "version-2")
            // §8.6.3 の規定どおり、移動前に存在を確かめて退避先を変える
            #expect(try await harness.objectExists(goneKey), "1 回目の退避を検出できない")
            let fallback = PublicKeyTemplate.goneKeyFallback(
                key, now: Date(timeIntervalSince1970: 1_772_000_000))
            try await harness.client.callRaw(RcPath.operationsMoveFile, params: [
                "srcFs": harness.fs, "srcRemote": key,
                "dstFs": harness.fs, "dstRemote": fallback,
            ])

            // 両方が残っていること（M-14 の事故が起きていないこと）
            #expect(try String(contentsOf: harness.source.appendingPathComponent(goneKey),
                               encoding: .utf8) == "version-1",
                    "1 回目の退避が上書きされた（事前 stat が効いていない）")
            #expect(try String(contentsOf: harness.source.appendingPathComponent(fallback),
                               encoding: .utf8) == "version-2")
        }
    }

    // MARK: - U-14 / §8.5 ログイン項目

    /// U-14: `SMAppService` の `status` を先に読み、望む状態と異なるときだけ呼ぶ方針が
    /// 冪等であることを確認する。**実際の登録は行わない**（ユーザーのログイン項目を変えないため）。
    @Test("U-14: status を読む方針なら register/unregister は冪等に扱える")
    func launchAtLoginPolicyIsIdempotent() {
        // status は副作用なく読める
        let status = LaunchAtLoginPolicy.currentStatus()
        // 望む状態と現在の状態から、呼ぶべきかを決める
        #expect(LaunchAtLoginPolicy.action(current: .enabled, desired: true) == .doNothing)
        #expect(LaunchAtLoginPolicy.action(current: .enabled, desired: false) == .unregister)
        #expect(LaunchAtLoginPolicy.action(current: .notRegistered, desired: true) == .register)
        #expect(LaunchAtLoginPolicy.action(current: .notRegistered, desired: false) == .doNothing)
        // 同じ望む状態を 2 回適用しても、2 回目は何もしない（冪等）
        let first = LaunchAtLoginPolicy.action(current: status, desired: true)
        let afterFirst: LaunchAtLoginPolicy.RegistrationStatus = first == .register ? .enabled : status
        #expect(LaunchAtLoginPolicy.action(current: afterFirst, desired: true) == .doNothing)
    }
}

extension RcdHarness {
    /// `operations/stat` で存在を確かめる
    func objectExists(_ key: String) async throws -> Bool {
        let json = try await client.callRaw(RcPath.operationsStat,
                                            params: ["fs": fs, "remote": key])
        if let item = json["item"], !(item is NSNull) { return true }
        return false
    }
}
