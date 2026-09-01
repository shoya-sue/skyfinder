import Foundation

/// §15.1: 名前の階層。bundle identifier は変更不可。
///
/// リポジトリ名は将来変更される予定があるが、bundle identifier を追随させてはならない。
/// 変更すると Keychain の項目にアクセスできなくなり、SMAppService のログイン項目が孤児になり、
/// Application Support のプロファイル設定を見失う。
///
/// **ソースコード内でリポジトリ名を参照しないこと。**
public enum AppIdentity {
    /// 変更不可（§15.1 MUST）
    public static let bundleIdentifier = "dev.fracturelab.skyfolder"

    /// Keychain の service。bundle identifier と同一・変更不可。
    public static let keychainService = bundleIdentifier

    /// 表示名。変更可（表示のみに影響）
    public static let productName = "SkyFolder"

    /// R2 上のプローブキーの prefix（§4.4 手順 3/5 で PUT し §8.1 手順 0-c で掃除する）。
    /// 唯一「ユーザーの R2 バケット上に残る」名前。変更する場合は旧 prefix も掃除対象に含めること。
    public static let probeKeyPrefix = ".skyfolder-probe-"

    /// 過去に使っていた prefix。§15.1 の規定により掃除対象に含め続ける。
    public static let legacyProbeKeyPrefixes = [".r2finder-probe-"]

    /// 全 prefix（掃除に使う）
    public static var allProbeKeyPrefixes: [String] { [probeKeyPrefix] + legacyProbeKeyPrefixes }

    /// mountOpt.VolumeName（Finder に表示されうる。nfsmount では無視される場合がある・DD-001 F-08）
    public static func volumeName(alias: String) -> String { "\(productName)-\(alias)" }

    /// rcd に渡すリモート名。環境変数 RCLONE_CONFIG_<REMOTE>_<KEY> の <REMOTE> 部分。
    public static let remoteName = "R2"

    /// ローカルファイルを読むためのリモート名（秘密情報を含まない）。
    /// 恒久公開のアップロードに operations/copyfile を使うため必要（M-13）。
    public static let localRemoteName = "LOCAL"

    /// ローカルディレクトリを指す fs 文字列: "local:/path/to/dir"
    public static func localFs(directory: String) -> String {
        "\(localRemoteName.lowercased()):\(directory)"
    }

    /// rc 呼び出しで使う fs 文字列: "r2:{bucketName}"
    public static func fs(bucketName: String) -> String { "\(remoteName.lowercased()):\(bucketName)" }
}
