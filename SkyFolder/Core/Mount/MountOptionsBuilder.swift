import Foundation

/// §6.2: mount/mount に渡す vfsOpt / mountOpt / _filter を組み立てる。
///
/// **時間・サイズ系は「ナノ秒 / バイト」の整数**（U-02 で実測・文字列にしない）。
/// CLI の `--vfs-write-back 15s` とは表現が違うので混同しないこと。
public enum MountOptionsBuilder {

    public static let nanosecondsPerSecond: Int64 = 1_000_000_000
    public static let bytesPerGB: Int64 = 1024 * 1024 * 1024
    public static let bytesPerMB: Int64 = 1024 * 1024

    /// D-05: CacheMaxAge は 72 時間固定
    public static let cacheMaxAgeSeconds: Int64 = 72 * 3600
    /// §6.2: ChunkSizeLimit は 512M 固定
    public static let chunkSizeLimitBytes: Int64 = 512 * 1024 * 1024
    /// §6.2: AttrTimeout は 5 秒
    public static let attrTimeoutSeconds: Int64 = 5

    public static func vfsOpt(for bucket: BucketConfig, advanced: AdvancedSettings) -> [String: Any] {
        [
            // D-05。固定
            "CacheMode": advanced.vfsCacheMode,
            "CacheMaxSize": Int64(advanced.vfsCacheMaxSizeGB) * bytesPerGB,
            "CacheMaxAge": cacheMaxAgeSeconds * nanosecondsPerSecond,
            "WriteBack": Int64(advanced.vfsWriteBackSec) * nanosecondsPerSecond,
            "ChunkSize": Int64(advanced.vfsReadChunkSizeMB) * bytesPerMB,
            "ChunkSizeLimit": chunkSizeLimitBytes,
            "DirCacheTime": Int64(advanced.dirCacheTimeSec) * nanosecondsPerSecond,
            // S3 は変更通知非対応（DD-001 §6.3）
            "PollInterval": 0,
            // G-08: visibility=="public" のバケットにのみ true。
            // read-only を独立フィールドとして持たず visibility から導出する（§4.2）。
            "ReadOnly": bucket.isReadOnly(allowDirectWriteToPublic: advanced.allowDirectWriteToPublic),
        ]
    }

    public static func mountOpt(for bucket: BucketConfig) -> [String: Any] {
        [
            // nfsmount では無視される場合がある（DD-001 F-08）
            "VolumeName": AppIdentity.volumeName(alias: bucket.alias),
            "AttrTimeout": attrTimeoutSeconds * nanosecondsPerSecond,
        ]
    }

    /// §6.3 第 1 層: 除外パターン。長命な VFS に持続適用される（U-08 で実測）。
    public static func filter(advanced: AdvancedSettings) -> [String: Any]? {
        guard !advanced.excludes.isEmpty else { return nil }
        return ["ExcludeRule": advanced.excludes]
    }

    /// mount/mount のパラメータ一式。
    ///
    /// - `mountType` は **省略禁止**（CRIT-01）。省略すると `cmount` が選ばれ、
    ///   macFUSE 未導入の環境では失敗する。
    public static func mountParams(bucket: BucketConfig,
                                   advanced: AdvancedSettings,
                                   resolvedMountPoint: String) -> [String: Any] {
        var params: [String: Any] = [
            "fs": AppIdentity.fs(bucketName: bucket.bucketName),
            "mountPoint": resolvedMountPoint,
            // CRIT-01: 省略禁止
            "mountType": advanced.mountType,
            "vfsOpt": vfsOpt(for: bucket, advanced: advanced),
            "mountOpt": mountOpt(for: bucket),
        ]
        if let f = filter(advanced: advanced) {
            params["_filter"] = f
        }
        return params
    }
}
