import Foundation

/// §4.1: 保存先とファイル権限。すべて bundle identifier 由来（§15.1）。
public struct AppPaths: Sendable {
    public let applicationSupport: URL
    public let caches: URL
    public let logs: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        applicationSupport = home
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        caches = home
            .appendingPathComponent("Library/Caches", isDirectory: true)
            .appendingPathComponent(AppIdentity.bundleIdentifier, isDirectory: true)
        // ログは人が読む場所なのでプロダクト名を使う（§15.1・変更可）
        logs = home
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(AppIdentity.productName, isDirectory: true)
    }

    /// 非機密フィールド全般。0600。
    public var profilesJSON: URL { applicationSupport.appendingPathComponent("profiles.json") }

    /// §8.6.2 (a): 起動した rcd の PID と割り当てポート
    public var rcdPID: URL { applicationSupport.appendingPathComponent("rcd.pid") }

    /// §7.2: 発行履歴（key・発行時刻・期限のみ。URL は保存しない・SEC-G05）
    public var shareHistory: URL { applicationSupport.appendingPathComponent("share-history.json") }

    /// R-G10: 終了時に送り切れなかった未送信件数。**次回起動時に通知して消す。**
    ///
    /// ログアウト・シャットダウン時の待機は 20 秒で打ち切られる
    /// （OS の強制終了タイムアウトがあるため・`LifecyclePolicy.uploadWaitLimit`）。
    /// 打ち切られた事実をユーザーに伝える手段は**次回起動時の通知だけ**で、
    /// これが無いと「保存したはずのものがクラウドに無い」ことに気づけない。
    public var pendingUploadsAtExit: URL {
        applicationSupport.appendingPathComponent("pending-at-exit.json")
    }

    /// VFS キャッシュ。0700。
    public func cacheDir(profileId: String) -> URL {
        caches.appendingPathComponent(profileId, isDirectory: true)
    }

    /// rclone のログ。0600。
    public func logFile(profileId: String) -> URL {
        logs.appendingPathComponent("\(profileId).log")
    }

    /// 既定のマウントパスの親（§15.1: 既定値にすぎず、ユーザーが mountPath で自由に変更できる）
    public static func defaultMountRoot(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        home.appendingPathComponent(AppIdentity.productName, isDirectory: true)
    }

    /// 起動時に必要なディレクトリを用意する。冪等。
    public func ensureDirectories(profileId: String?) throws {
        try Self.ensureDirectory(applicationSupport, mode: 0o700)
        try Self.ensureDirectory(caches, mode: 0o700)
        try Self.ensureDirectory(logs, mode: 0o700)
        if let profileId {
            try Self.ensureDirectory(cacheDir(profileId: profileId), mode: 0o700)
        }
    }

    /// ディレクトリを用意する。既にあれば権限だけ合わせる（冪等）。
    public static func ensureDirectory(_ url: URL, mode: Int) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try fm.createDirectory(at: url, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: mode])
        } else {
            try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }
}
