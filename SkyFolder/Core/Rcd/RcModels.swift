import Foundation

/// RC API のエンドポイント名。§06 の呼び出し規約から逸脱しないため、
/// パス文字列をここに集約して呼び出し側では文字列リテラルを書かない。
public enum RcPath {
    public static let coreVersion = "core/version"
    public static let coreStats = "core/stats"
    public static let vfsStats = "vfs/stats"
    public static let vfsRefresh = "vfs/refresh"
    public static let mountMount = "mount/mount"
    public static let mountUnmount = "mount/unmount"
    public static let mountUnmountAll = "mount/unmountall"
    public static let mountListMounts = "mount/listmounts"
    public static let mountTypes = "mount/types"
    public static let operationsList = "operations/list"
    public static let operationsStat = "operations/stat"
    public static let operationsUploadFile = "operations/uploadfile"
    public static let operationsDeleteFile = "operations/deletefile"
    public static let operationsMoveFile = "operations/movefile"
    public static let operationsCopyFile = "operations/copyfile"
    public static let operationsPublicLink = "operations/publiclink"
    public static let optionsGet = "options/get"
    public static let optionsSet = "options/set"
    public static let configDump = "config/dump"
    public static let jobStatus = "job/status"
    public static let rcList = "rc/list"
}

/// RC API のエラー。分類は「メッセージ先頭ではなく末尾の実体」で行う（M-07）。
public struct RcError: Error, Sendable, CustomStringConvertible {
    public let path: String
    public let statusCode: Int
    /// rclone が返した `error` フィールドの本文（無ければ生のレスポンス）
    public let message: String

    public init(path: String, statusCode: Int, message: String) {
        self.path = path
        self.statusCode = statusCode
        self.message = message
    }

    public var description: String { "[\(path)] HTTP \(statusCode): \(message)" }

    // MARK: - §8.6.1 冪等性の判定
    //
    // 「すでにその状態である」ことを示すエラーは、失敗ではなく成功として扱う。
    // これを守らないと、ボタンの二度押し・自動再マウントとの競合・再起動直後の操作が
    // すべてエラーダイアログになる。

    /// mount/mount の 2 回目。実測:
    /// `failed to mount FUSE fs: mount: localhost:/ is already mounted at {path}: ... exit status 78`
    ///
    /// nfsmount でも「FUSE」と表示される（M-07）。判定は末尾の実体で行う。
    public var meansAlreadyMounted: Bool {
        let m = message.lowercased()
        return m.contains("already mounted") || m.contains("exit status 78")
    }

    /// mount/unmount の 2 回目 / 存在しないパス。実測: `"mount not found"` / HTTP 500
    public var meansMountNotFound: Bool {
        message.lowercased().contains("mount not found")
    }

    /// operations/deletefile を存在しないキーに対して実行した場合（G1-9 ⑧ で確認する）。
    /// 接続テストの後片付けと share-staging/ の掃除で重複実行が起こりうる。
    public var meansObjectNotFound: Bool {
        let m = message.lowercased()
        return m.contains("object not found")
            || m.contains("directory not found")
            || m.contains("no such file")
            || m.contains("404")
    }

    /// 認証・権限エラー（E-06）。
    /// MUST: この判定は必ずバケット名付きの操作の結果に対して行うこと（DD-001 F-01）。
    public var meansForbidden: Bool {
        let m = message.lowercased()
        return m.contains("403") || m.contains("accessdenied") || m.contains("access denied")
            || m.contains("invalidaccesskeyid") || m.contains("signaturedoesnotmatch")
    }

    /// バケットが存在しない（E-07）
    public var meansBucketNotFound: Bool {
        let m = message.lowercased()
        return m.contains("nosuchbucket") || m.contains("bucket not found")
    }

    /// ディレクトリは共有できない（M-11 (3)）
    public var meansCantShareDirectories: Bool {
        message.lowercased().contains("can't share directories")
            || message.lowercased().contains("cant share directories")
    }
}

// MARK: - 応答モデル

public struct RcCoreVersion: Decodable, Sendable {
    public let version: String
    public let os: String?
    public let arch: String?
    public let goVersion: String?

    enum CodingKeys: String, CodingKey {
        case version, os, arch
        case goVersion = "goVersion"
    }
}

public struct RcMountPoint: Decodable, Sendable, Equatable, Identifiable {
    /// rclone が実際にマウントした絶対パス（§6.2 RULE の `mountPoint`）
    public let mountPoint: String
    public let fs: String
    public let mountedOn: Date?

    public var id: String { mountPoint }

    enum CodingKeys: String, CodingKey {
        case mountPoint = "MountPoint"
        case fs = "Fs"
        case mountedOn = "MountedOn"
    }

    public init(mountPoint: String, fs: String, mountedOn: Date? = nil) {
        self.mountPoint = mountPoint
        self.fs = fs
        self.mountedOn = mountedOn
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mountPoint = try c.decode(String.self, forKey: .mountPoint)
        fs = try c.decode(String.self, forKey: .fs)
        if let raw = try? c.decode(String.self, forKey: .mountedOn) {
            mountedOn = ISO8601DateFormatter.rcloneParsers.compactMap { $0.date(from: raw) }.first
        } else {
            mountedOn = nil
        }
    }
}

public struct RcListMountsResponse: Decodable, Sendable {
    public let mountPoints: [RcMountPoint]
    enum CodingKeys: String, CodingKey { case mountPoints }
}

public struct RcMountTypesResponse: Decodable, Sendable {
    public let mountTypes: [String]
}

/// §6.4: core/stats
public struct RcCoreStats: Decodable, Sendable, Equatable {
    public let bytes: Int64
    public let speed: Double
    public let transfers: Int
    public let errors: Int
    public let checks: Int?
    public let elapsedTime: Double?
    public let lastError: String?

    public init(bytes: Int64 = 0, speed: Double = 0, transfers: Int = 0, errors: Int = 0,
                checks: Int? = nil, elapsedTime: Double? = nil, lastError: String? = nil) {
        self.bytes = bytes; self.speed = speed; self.transfers = transfers
        self.errors = errors; self.checks = checks
        self.elapsedTime = elapsedTime; self.lastError = lastError
    }
}

/// §6.4 / M-03: vfs/stats。応答の diskCache ブロックにキーがある（実測でキー名を確認）。
public struct RcVfsStats: Decodable, Sendable, Equatable {
    public struct DiskCache: Decodable, Sendable, Equatable {
        public let uploadsQueued: Int
        public let uploadsInProgress: Int
        public let bytesUsed: Int64
        public let files: Int
        public let erroredFiles: Int
        public let outOfSpace: Bool

        public init(uploadsQueued: Int = 0, uploadsInProgress: Int = 0, bytesUsed: Int64 = 0,
                    files: Int = 0, erroredFiles: Int = 0, outOfSpace: Bool = false) {
            self.uploadsQueued = uploadsQueued
            self.uploadsInProgress = uploadsInProgress
            self.bytesUsed = bytesUsed
            self.files = files
            self.erroredFiles = erroredFiles
            self.outOfSpace = outOfSpace
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            uploadsQueued = (try? c.decode(Int.self, forKey: .uploadsQueued)) ?? 0
            uploadsInProgress = (try? c.decode(Int.self, forKey: .uploadsInProgress)) ?? 0
            bytesUsed = (try? c.decode(Int64.self, forKey: .bytesUsed)) ?? 0
            files = (try? c.decode(Int.self, forKey: .files)) ?? 0
            erroredFiles = (try? c.decode(Int.self, forKey: .erroredFiles)) ?? 0
            outOfSpace = (try? c.decode(Bool.self, forKey: .outOfSpace)) ?? false
        }

        enum CodingKeys: String, CodingKey {
            case uploadsQueued, uploadsInProgress, bytesUsed, files, erroredFiles, outOfSpace
        }
    }

    public let diskCache: DiskCache?

    /// §5.2「未送信 N 件」= uploadsQueued + uploadsInProgress（M-03）
    public var pendingUploads: Int {
        guard let d = diskCache else { return 0 }
        return d.uploadsQueued + d.uploadsInProgress
    }

    /// erroredFiles が 0 でない場合は別途エラー表示を出す（黙って失敗させない）
    public var erroredFiles: Int { diskCache?.erroredFiles ?? 0 }
    public var cacheBytesUsed: Int64 { diskCache?.bytesUsed ?? 0 }

    public init(diskCache: DiskCache?) { self.diskCache = diskCache }
}

public struct RcPublicLinkResponse: Decodable, Sendable {
    public let url: String
}

public struct RcJobStatus: Decodable, Sendable {
    public let id: Int
    public let finished: Bool
    public let success: Bool
    public let error: String?
    public let duration: Double?
}

public struct RcAsyncJobHandle: Decodable, Sendable {
    public let jobid: Int
}

public struct RcListEntry: Decodable, Sendable, Identifiable, Equatable {
    public let path: String
    public let name: String
    public let size: Int64
    public let mimeType: String?
    public let modTime: Date?
    public let isDir: Bool

    public var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path = "Path"
        case name = "Name"
        case size = "Size"
        case mimeType = "MimeType"
        case modTime = "ModTime"
        case isDir = "IsDir"
    }

    public init(path: String, name: String, size: Int64,
                mimeType: String? = nil, modTime: Date? = nil, isDir: Bool = false) {
        self.path = path; self.name = name; self.size = size
        self.mimeType = mimeType; self.modTime = modTime; self.isDir = isDir
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        name = try c.decode(String.self, forKey: .name)
        size = (try? c.decode(Int64.self, forKey: .size)) ?? 0
        mimeType = try? c.decode(String.self, forKey: .mimeType)
        isDir = (try? c.decode(Bool.self, forKey: .isDir)) ?? false
        if let raw = try? c.decode(String.self, forKey: .modTime) {
            modTime = ISO8601DateFormatter.rcloneParsers.compactMap { $0.date(from: raw) }.first
        } else {
            modTime = nil
        }
    }
}

public struct RcListResponse: Decodable, Sendable {
    public let list: [RcListEntry]
}

extension ISO8601DateFormatter {
    /// rclone は秒の小数部を付けたり付けなかったりする
    static let rcloneParsers: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}
