import Foundation

/// §10.1 エラーカタログ。
///
/// すべてのエラーは「何が起きたか」ではなく**「次に何をすればよいか」**を主文にする。
/// CLI 版ではエラーはターミナルに出た文字列だったが、GUI ではユーザーがログを読まない前提で設計する。
public struct CatalogedError: Sendable, Identifiable, Equatable {
    public enum Action: Sendable, Equatable {
        case openDiagnostics
        case openSettings
        case openDashboard(URL?)
        case openFinder(String)
        case retry
        case checkForUpdate
        case openShareDialog
        case runConnectionTest
        case switchToPermanentPublish
        case showSteps
        case saveAnyway
        case publishWithoutStripping
    }

    public let id: String
    /// 主文。「次に何をすればよいか」
    public let message: String
    /// rclone のエラー本文など。UI では折りたたむ。
    public let detail: String?
    public let actions: [Action]

    public init(id: String, message: String, detail: String? = nil, actions: [Action] = []) {
        self.id = id
        self.message = message
        self.detail = detail
        self.actions = actions
    }
}

public enum ErrorCatalog {

    public static let cloudflareR2Dashboard = URL(string: "https://dash.cloudflare.com/?to=/:account/r2")

    public static func e01RcdUnavailable(detail: String? = nil) -> CatalogedError {
        .init(id: "E-01", message: "内部エンジンを起動できませんでした。アプリを再起動してください。",
              detail: detail, actions: [.openDiagnostics, .retry])
    }

    public static func e02RcloneTooOld(found: String) -> CatalogedError {
        .init(id: "E-02", message: "アプリの内部コンポーネントが古いため動作できません。",
              detail: "同梱 rclone: \(found)", actions: [.checkForUpdate])
    }

    public static func e03NoNfsmount(available: [String]) -> CatalogedError {
        .init(id: "E-03", message: "このビルドはマウント機能に対応していません。共有機能のみ利用できます。",
              detail: "mount/types: \(available.joined(separator: ", "))",
              actions: [.openDiagnostics])
    }

    public static func e04ForeignStaleMount(path: String) -> CatalogedError {
        .init(id: "E-04",
              message: "\(path) が別のプロセスによってマウントされています。Finder で取り出してから再試行してください。",
              actions: [.openFinder(path), .retry])
    }

    public static func e05MountPointNotEmpty(path: String) -> CatalogedError {
        .init(id: "E-05", message: "\(path) には既にファイルがあります。空のフォルダを指定してください。",
              actions: [.openSettings, .openFinder(path)])
    }

    /// MUST — 誤診断を生む導線を作らない（DD-001 F-01）。
    /// この文言を**バケット名なしの操作**の結果として出してはならない。
    public static func e06Forbidden(detail: String? = nil) -> CatalogedError {
        .init(id: "E-06",
              message: "R2 に接続できませんでした。API トークンの権限（Object Read & Write）と対象バケットの指定を確認してください。",
              detail: detail, actions: [.openSettings, .openDashboard(cloudflareR2Dashboard)])
    }

    public static func e07BucketNotFound(bucketName: String) -> CatalogedError {
        .init(id: "E-07", message: "バケット「\(bucketName)」が見つかりません。名前を確認してください。",
              actions: [.openSettings])
    }

    public static func e08KeychainReadFailed() -> CatalogedError {
        .init(id: "E-08",
              message: "保存された認証情報を読み取れませんでした。Secret Access Key を再入力してください。",
              actions: [.openSettings])
    }

    public static func e09StripFailed(detail: String? = nil) -> CatalogedError {
        .init(id: "E-09", message: "画像のメタデータを除去できなかったため、公開を中止しました。",
              detail: detail, actions: [.retry, .publishWithoutStripping])
    }

    public static func e10NoPublicBaseURL() -> CatalogedError {
        .init(id: "E-10", message: "公開 URL を発行するには、公開用ドメインの設定が必要です。",
              actions: [.openSettings])
    }

    public static func e11ExpireTooLong() -> CatalogedError {
        .init(id: "E-11", message: "期限付きリンクは最長 7 日です。それ以上の共有には恒久公開をご利用ください。",
              actions: [.switchToPermanentPublish])
    }

    public static func e12UploadFailed(fileName: String, detail: String?) -> CatalogedError {
        .init(id: "E-12", message: "\(fileName) のアップロードに失敗しました。",
              detail: detail, actions: [.retry])
    }

    public static func e13PublicURLUnreachable(bucketName: String, baseURL: String) -> CatalogedError {
        .init(id: "E-13",
              message: "バケット「\(bucketName)」にカスタムドメイン \(baseURL) が接続されていないようです。公開 URL は使えませんが、マウントは利用できます。",
              actions: [.openDashboard(cloudflareR2Dashboard), .showSteps, .saveAnyway])
    }

    /// E-14: read-only の public マウントへ Finder から書込み・削除・リネームを試みた。
    ///
    /// **できないこと（明記）**: Finder が出す失敗ダイアログ自体は抑制できない（M-01 / M-02）。
    /// 書込み拒否は VFS 層で起きるため、アプリはその経路に居ない。
    /// アプリができるのは、そのあとに通知で理由と正しい手順を案内することだけである。
    public static func e14ReadOnlyWriteAttempt(alias: String) -> CatalogedError {
        .init(id: "E-14",
              message: "公開バケットは読み取り専用です。公開するには「共有…」をお使いください。",
              detail: "対象: \(alias)", actions: [.openShareDialog])
    }

    public static func e15MountAuthFailed(alias: String, detail: String?) -> CatalogedError {
        .init(id: "E-15", message: "\(alias) をマウントできませんでした。R2 への接続を確認してください。",
              detail: detail, actions: [.runConnectionTest, .openSettings])
    }

    /// 例外から表示用のカタログ項目を作る。
    public static func from(_ error: Error) -> CatalogedError {
        switch error {
        case let e as MountError:
            switch e {
            case .mountTypeUnavailable(_, let available): return e03NoNfsmount(available: available)
            case .foreignStaleMount(let path): return e04ForeignStaleMount(path: path)
            case .mountPointNotEmpty(let path): return e05MountPointNotEmpty(path: path)
            case .authenticationFailed(let alias, let detail):
                return e15MountAuthFailed(alias: alias, detail: detail)
            case .mountFailed(let alias, let detail):
                return e15MountAuthFailed(alias: alias, detail: detail)
            case .mountPointCreationFailed(let path, let detail):
                return .init(id: "E-05", message: "\(path) を作成できませんでした。", detail: detail,
                             actions: [.openSettings])
            }
        case let e as ShareError:
            switch e {
            case .noPublicDestination: return e10NoPublicBaseURL()
            case .expireTooLong, .expireInvalid: return e11ExpireTooLong()
            case .uploadFailed(let name, let detail): return e12UploadFailed(fileName: name, detail: detail)
            default:
                return .init(id: e.catalogID, message: e.errorDescription ?? "エラーが発生しました。",
                             actions: [.retry])
            }
        case let e as ImageMetadataError:
            return e09StripFailed(detail: e.errorDescription)
        case is KeychainError:
            return e08KeychainReadFailed()
        case let e as RcdSupervisorError:
            if case .rcloneTooOld(let found, _) = e { return e02RcloneTooOld(found: found) }
            return e01RcdUnavailable(detail: e.errorDescription)
        case let e as RcError:
            if e.meansBucketNotFound { return e07BucketNotFound(bucketName: "") }
            if e.meansForbidden { return e06Forbidden(detail: e.message) }
            return .init(id: "E-12", message: "操作に失敗しました。", detail: e.message, actions: [.retry])
        default:
            return .init(id: "E-00", message: error.localizedDescription, actions: [.retry])
        }
    }
}
