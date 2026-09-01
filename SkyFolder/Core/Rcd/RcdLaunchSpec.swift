import Foundation

/// R2 の認証情報。Keychain から取り出してメモリ上でのみ扱う（§4.1）。
public struct R2Credentials: Sendable, Equatable {
    public let accessKeyId: String
    public let secretAccessKey: String

    public init(accessKeyId: String, secretAccessKey: String) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
    }
}

/// §6.1: rcd の起動コマンドと環境変数。
///
/// **秘密情報を一切コマンドライン引数に置かない**（引数は `ps` で全ユーザーから可読・SEC-G02）。
/// rc-user / rc-pass も含めてすべて環境変数から注入する。
///
/// 純粋な値として組み立てるので、T-G04（`ps` に secret が出ないこと）を単体テストで検査できる。
public struct RcdLaunchSpec: Sendable, Equatable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let rcUser: String
    public let rcPassword: String

    /// rcd を再起動しないと反映されない設定の指紋。
    ///
    /// リモート定義とグローバルオプションは**環境変数でしか渡せない**（§6.2 注入経路表）ため、
    /// これらが変わったときは rcd を作り直す必要がある。
    /// 逆に vfsOpt / mountOpt / _filter は `mount/mount` の呼び出しごとに渡すので再起動は要らない。
    ///
    /// rc-user / rc-pass は起動ごとに変わるので指紋から外す（外さないと毎回「変わった」になる）。
    public var restartSignature: String {
        environment
            .filter { $0.key != "RCLONE_RC_USER" && $0.key != "RCLONE_RC_PASS" }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
            + "\n--\n" + arguments.joined(separator: "\u{1}")
    }

    /// SEC-G01: rc-user / rc-pass を作り直した複製を返す。
    ///
    /// `RcdSupervisor` が**起動のたびに必ず**これを適用する。
    /// 呼び出し側が spec を使い回しても認証情報が使い回されないよう、
    /// 「起動ごとの乱数」という性質を構造で担保するための経路。
    public func regeneratingCredentials() -> RcdLaunchSpec {
        RcdLaunchSpec(executableURL: executableURL,
                      arguments: arguments,
                      environment: environment,
                      rcUser: RandomToken.make(length: 24),
                      rcPassword: RandomToken.make(length: 32))
    }

    /// 内部用。環境変数の rc 認証情報を新しい値で上書きしてから保持する。
    private init(executableURL: URL, arguments: [String], environment: [String: String],
                 rcUser: String, rcPassword: String) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.rcUser = rcUser
        self.rcPassword = rcPassword
        var env = environment
        env["RCLONE_RC_USER"] = rcUser
        env["RCLONE_RC_PASS"] = rcPassword
        self.environment = env
    }

    /// 環境変数に載る値のうち、ログ等に出してはならないもの（SEC-G04 のマスク対象）。
    ///
    /// キー名は `AppIdentity.remoteName` から組み立てる — 直書きすると、
    /// リモート名を変えた瞬間に**無言で空配列を返す**（マスクが外れたことに気づけない）。
    public var secretValues: [String] {
        let r = AppIdentity.remoteName.uppercased()
        return [rcPassword,
                environment["RCLONE_CONFIG_\(r)_SECRET_ACCESS_KEY"] ?? "",
                environment["RCLONE_CONFIG_\(r)_ACCESS_KEY_ID"] ?? ""]
            .filter { !$0.isEmpty }
    }

    /// SEC-G04 のマスク対象になる rc ユーザー名
    public var maskableUserNames: [String] { [rcUser] }

    public init(rcloneURL: URL,
                profile: Profile,
                credentials: R2Credentials,
                paths: AppPaths,
                rcUser: String = RandomToken.make(length: 24),
                rcPassword: String = RandomToken.make(length: 32),
                logLevel: String = "INFO") {
        self.executableURL = rcloneURL
        self.rcUser = rcUser
        self.rcPassword = rcPassword

        // ---- コマンドライン引数（秘密情報を一切置かない）----
        self.arguments = [
            "rcd",
            // 0 = 空きポート自動割当。固定ポートを使わない（SEC-G01）
            "--rc-addr", "127.0.0.1:0",
            // §4.1 MUST: 既定の rclone.conf を読まない・書かない。設定ファイルは生成しない
            "--config", "",
            "--cache-dir", paths.cacheDir(profileId: profile.id).path,
            "--log-file", paths.logFile(profileId: profile.id).path,
            "--log-level", logLevel,
            // --rc-serve は v1.0 では付けない（確定・§6.1）
        ]

        // ---- 環境変数（すべての秘密情報はここから注入する）----
        var env: [String: String] = [:]
        // rc の認証情報。引数に置かない（SEC-G01 / SEC-G02）
        env["RCLONE_RC_USER"] = rcUser
        env["RCLONE_RC_PASS"] = rcPassword

        // リモート定義（G-04 第 1 案。U-01 で実機検証済み）
        let r = AppIdentity.remoteName.uppercased()
        env["RCLONE_CONFIG_\(r)_TYPE"] = "s3"
        env["RCLONE_CONFIG_\(r)_PROVIDER"] = "Cloudflare"
        env["RCLONE_CONFIG_\(r)_ACCESS_KEY_ID"] = credentials.accessKeyId
        env["RCLONE_CONFIG_\(r)_SECRET_ACCESS_KEY"] = credentials.secretAccessKey
        env["RCLONE_CONFIG_\(r)_ENDPOINT"] = profile.resolvedEndpoint
        env["RCLONE_CONFIG_\(r)_ACL"] = "private"
        // DD-001 §6.2: バケット作成権限がないトークンで必須
        env["RCLONE_CONFIG_\(r)_NO_CHECK_BUCKET"] = "true"

        // ローカルファイルの読み出し用リモート（秘密情報を含まない）。
        // 恒久公開のアップロードは operations/copyfile で行うため、
        // ローカル側にも名前の付いたリモートが要る。
        // uploadfile(multipart) を使わない理由は ShareService の注記を参照（M-13）。
        env["RCLONE_CONFIG_\(AppIdentity.localRemoteName.uppercased())_TYPE"] = "local"

        // K-02（NFC 正規化）: --no-unicode-normalization は既定 false のまま維持する。
        // 環境変数でもフラグでも変更しない。アプリの設定項目としても提供しない。

        // グローバル / バックエンドのオプション（mount/mount では渡せない項目・§6.2 注入経路表）
        env["RCLONE_TRANSFERS"] = String(profile.advanced.transfers)
        env["RCLONE_S3_CHUNK_SIZE"] = "\(profile.advanced.s3ChunkSizeMB)M"
        env["RCLONE_S3_UPLOAD_CUTOFF"] = "\(profile.advanced.s3UploadCutoffMB)M"
        // nfs-cache-handle-limit は渡さない。既定値が既に 1000000 で
        // DD-001 §6.3 の指定値と一致する（実測・U-09）

        self.environment = env
    }

    /// 検証専用の初期化子（type=local のリモートで RC API の挙動を確かめるときに使う）。
    /// 実 R2 アカウントを持たない環境で §12 の多くを検査できる。
    public init(rcloneURL: URL,
                localRemoteName: String,
                cacheDir: URL,
                logFile: URL,
                rcUser: String = RandomToken.make(length: 24),
                rcPassword: String = RandomToken.make(length: 32),
                logLevel: String = "INFO") {
        self.executableURL = rcloneURL
        self.rcUser = rcUser
        self.rcPassword = rcPassword
        self.arguments = [
            "rcd",
            "--rc-addr", "127.0.0.1:0",
            "--config", "",
            "--cache-dir", cacheDir.path,
            "--log-file", logFile.path,
            "--log-level", logLevel,
        ]
        var env: [String: String] = [:]
        env["RCLONE_RC_USER"] = rcUser
        env["RCLONE_RC_PASS"] = rcPassword
        env["RCLONE_CONFIG_\(localRemoteName.uppercased())_TYPE"] = "local"
        self.environment = env
    }
}
