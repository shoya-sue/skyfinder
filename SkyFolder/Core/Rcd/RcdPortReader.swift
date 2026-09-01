import Foundation

/// rcd が割り当てられた待受ポートを取り出す。
///
/// **M-12（実測・本実装で判明）**: §6.1 が必須としている `--log-file` を指定すると、
/// `NOTICE: Serving remote control on http://127.0.0.1:{port}/` は
/// **stdout でも stderr でもなくログファイルに出る**（stdout / stderr はどちらも 0 バイト）。
/// 設計書 §8.1 手順 4 / U-05 / T-G02 の「stderr から取得する」は
/// `--log-file` なしで測った結果であり、そのまま実装すると永久に待つ。
///
/// ログファイルは再起動をまたいで追記されるため、**起動前のサイズを記録し、そこから後ろだけを読む**。
/// これをしないと前回起動時の古いポートを掴む（CRIT-03 と同種の事故になる）。
public struct RcdPortReader: Sendable {
    /// `Serving remote control on http://127.0.0.1:54681/`
    private static let pattern = try! NSRegularExpression(
        pattern: #"Serving remote control on https?://(?:127\.0\.0\.1|localhost):(\d+)"#)

    public let logFile: URL
    /// 起動直前のログファイルのサイズ。ここより後ろだけを走査する。
    public let startOffset: UInt64

    public init(logFile: URL) {
        self.logFile = logFile
        let size = (try? FileManager.default.attributesOfItem(atPath: logFile.path)[.size] as? UInt64) ?? nil
        self.startOffset = size ?? 0
    }

    public static func parsePort(in text: String) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = pattern.firstMatch(in: text, range: range),
              let r = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[r])
    }

    /// ログファイルの新しい部分から 1 回だけ読み取りを試みる。
    public func tryRead() -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: logFile) else { return nil }
        defer { try? handle.close() }
        do {
            try handle.seek(toOffset: startOffset)
            let data = try handle.readToEnd() ?? Data()
            guard let text = String(data: data, encoding: .utf8) else { return nil }
            return Self.parsePort(in: text)
        } catch {
            return nil
        }
    }

    /// ポートが現れるまで待つ。
    /// - Parameter extraSources: ログファイル以外にも走査する文字列を返すクロージャ
    ///   （将来 rclone が stderr に戻した場合の保険。実測では空になる）
    public func wait(timeout: TimeInterval,
                     pollInterval: TimeInterval = 0.05,
                     extraSources: (() -> String)? = nil) async throws -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let port = tryRead() { return port }
            if let extra = extraSources?(), let port = Self.parsePort(in: extra) { return port }
            try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        throw RcdSupervisorError.startupTimedOut(seconds: timeout)
    }
}
