import Foundation

/// §7.2 / SEC-G05: 期限付きリンクの発行履歴。
///
/// **記録するのは key・発行時刻・期限の 3 つのみ。URL 文字列は保存しない。**
/// 保存すると、失効前の署名付き URL がディスク上に残り再配布経路になる。
///
/// 「履歴から再コピー」機能を実装してはならない — 実装するには URL の保存が必要になる。
/// クリップボードを失った場合は再発行する（署名はローカル計算なので安全・§7.2）。
public struct ShareHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public let bucketName: String
    public let key: String
    public let issuedAt: Date
    public let expiresAt: Date

    public var id: String { "\(bucketName)/\(key)@\(issuedAt.timeIntervalSince1970)" }

    public init(bucketName: String, key: String, issuedAt: Date, expiresAt: Date) {
        self.bucketName = bucketName
        self.key = key
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date()) -> Bool { now >= expiresAt }
}

public final class ShareHistoryStore: @unchecked Sendable {
    /// ローカルに直近 50 件を記録する
    public static let limit = 50

    private let fileURL: URL
    private let lock = NSLock()

    public init(fileURL: URL) { self.fileURL = fileURL }

    public convenience init(paths: AppPaths = AppPaths()) {
        self.init(fileURL: paths.shareHistory)
    }

    public func load() -> [ShareHistoryEntry] {
        lock.lock(); defer { lock.unlock() }
        return loadUnlocked()
    }

    private func loadUnlocked() -> [ShareHistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ShareHistoryEntry].self, from: data)) ?? []
    }

    public func append(_ entry: ShareHistoryEntry) {
        lock.lock(); defer { lock.unlock() }
        var entries = loadUnlocked()
        entries.insert(entry, at: 0)
        if entries.count > Self.limit { entries = Array(entries.prefix(Self.limit)) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? AtomicFileWriter.write(data, to: fileURL, mode: 0o600)
        }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: fileURL)
    }
}
