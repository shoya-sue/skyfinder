import Foundation
@testable import SkyFolderKit

enum TestSupport {

    /// リポジトリのルート（`#filePath` から辿る）
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)      // Tests/SkyFolderKitTests/TestSupport.swift
            .deletingLastPathComponent()      // Tests/SkyFolderKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo
    }

    /// 同梱する rclone。統合テストで使う。
    static var rcloneURL: URL {
        repoRoot.appendingPathComponent("SkyFolder/Resources/rclone")
    }

    static var rcloneAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: rcloneURL.path)
    }

    /// テストごとに独立した一時ディレクトリ
    static func makeTemporaryDirectory(_ label: String = "test") -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("skyfolder-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **マウントを含む木を消そうとしない。**
    ///
    /// サーバ（rcd）が死んだ NFS マウントは hard mount で、その中へ入る操作は永久に返らない。
    /// `FileManager.removeItem` は再帰的に walk するので、テストプロセスごと固まる。
    /// カーネルのマウント表だけを見て（＝ファイルシステムに触れずに）判定する。
    static func remove(_ url: URL) {
        let target = SystemMountTable.resolveTextually(url.path)
        let mounted = SystemMountTable.entries().contains { entry in
            let on = SystemMountTable.resolveTextually(entry.mountedOn)
            return on == target || on.hasPrefix(target + "/")
        }
        guard !mounted else {
            FileHandle.standardError.write(Data(
                "⚠️ マウントを含むため削除しません: \(url.path)\n".utf8))
            return
        }
        try? FileManager.default.removeItem(at: url)
    }

    static func sampleProfile(id: String = "prof_TEST0000000000000000000",
                              buckets: [BucketConfig]? = nil) -> Profile {
        Profile(id: id,
                displayName: "fracturelab",
                accountId: String(repeating: "0123abcd", count: 4),
                buckets: buckets ?? [
                    BucketConfig(alias: "private", bucketName: "flab-stor-private",
                                 visibility: .privateBucket,
                                 mountPath: "~/SkyFolder/fracturelab/private"),
                    BucketConfig(alias: "public", bucketName: "flab-stor-public",
                                 visibility: .publicBucket,
                                 mountPath: "~/SkyFolder/fracturelab/public",
                                 publicBaseURL: "https://files.fracturelab.dev"),
                ])
    }
}

/// 小さな相互排他ボックス（テストがスレッド境界を跨いで結果を受け取るため）
final class Mutex<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
}
