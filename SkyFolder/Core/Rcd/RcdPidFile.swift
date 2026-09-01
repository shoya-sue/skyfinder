import Foundation

/// §8.6.2 (a): 起動した rcd の PID と割り当てポートを記録する。
///
/// **rc-user / rc-pass は書かない**（SEC-G01）。書けば孤児に RC API を呼べるようになるが、
/// それは「認証情報を永続化しない」という原則そのものへの違反になる。
/// SIGTERM だけで回収が完結することは実測済み（M-08）。
public struct RcdPidRecord: Codable, Sendable, Equatable {
    public let pid: Int32
    public let port: Int
    /// PID の使い回しを踏まないための照合用（§8.6.2 (b)）
    public let executablePath: String
    public let startedAt: Date

    public init(pid: Int32, port: Int, executablePath: String, startedAt: Date = Date()) {
        self.pid = pid
        self.port = port
        self.executablePath = executablePath
        self.startedAt = startedAt
    }
}

public struct RcdPidFile: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func read() -> RcdPidRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RcdPidRecord.self, from: data)
    }

    public func write(_ record: RcdPidRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFileWriter.write(try encoder.encode(record), to: url, mode: 0o600)
    }

    /// §8.6.2 (d): 終了時に削除する。異常終了で残った場合は (b) が回収する。
    /// 2 回呼んでもエラーにしない（冪等）。
    public func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}
