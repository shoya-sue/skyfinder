import Foundation

/// E-14 の検知手段。
///
/// read-only の public マウントへの書込み拒否は **VFS 層**で起きるため、アプリはその経路に居ない（M-01）。
/// したがって rclone のログファイルを監視し、public マウントに対する
/// `permission denied` / `Input/output error` の行を検出したときに通知を出す。
/// ポーリングではなくファイル監視で足りる。
///
/// **できないこと（明記）**: Finder が出す失敗ダイアログ自体は抑制できない。
/// できるのは、OS のダイアログに**加えて**分かりやすい案内を出すことまでである。
public final class LogWatcher: @unchecked Sendable {

    public struct Detection: Sendable, Equatable {
        public let line: String
        public let matchedAlias: String?
    }

    private let url: URL
    private let queue = DispatchQueue(label: "\(AppIdentity.bundleIdentifier).logwatcher")
    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var offset: UInt64 = 0
    private var handler: (@Sendable (Detection) -> Void)?
    /// read-only でマウントしているバケットの alias → 実マウントパス
    private var readOnlyMounts: [String: String] = [:]

    /// 実測（M-17）: ログレベル INFO（§6.1 の既定）で出るのは
    /// `ERROR : nfs: Error Creating: Read only file system` の 1 種類だけ。
    ///
    /// - 設計書 M-02 が挙げる `permission denied` / `Input/output error` は
    ///   **NFS クライアントが呼び出し側へ返す errno** であって、rclone のログには出ない。
    ///   これらを検知語にしても発火しない。
    /// - **削除とリネームは INFO では 1 行も出ない**（DEBUG でも出ない）。
    ///   したがって E-14 で案内できるのは**書込み試行のときだけ**である。
    ///   削除・リネームは OS のダイアログだけがユーザーに見えることになる。
    private static let denialMarkers = ["read only file system"]

    /// macOS が勝手に作るメタデータファイル。
    ///
    /// Finder が read-only マウントを開くだけで `._*` や `.DS_Store` の作成を試み、
    /// そのたびに拒否ログが出る（実測で `._existing.txt` を観測）。
    /// これでユーザーへ通知を出すと、**何もしていないのに警告が鳴り続ける**。
    /// DD-001 R-10 / R-G05 と同じ問題なので、通知の対象から外す。
    private static let ignoredNames = ["._", ".DS_Store", ".Spotlight-V100", ".Trashes",
                                       ".fseventsd", ".TemporaryItems", ".apDisk"]

    private static func isSystemMetadataAttempt(_ line: String) -> Bool {
        ignoredNames.contains { line.contains($0) }
    }

    public init(logFile: URL) { self.url = logFile }

    public func setReadOnlyMounts(_ mounts: [String: String]) {
        queue.sync { readOnlyMounts = mounts }
    }

    public func start(onDetection: @escaping @Sendable (Detection) -> Void) {
        queue.async { [self] in
            guard source == nil else { return }
            handler = onDetection
            // 既存分は読まない（起動前の失敗を今の操作として通知しないため）
            offset = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64)
                .flatMap { $0 } ?? 0

            fileDescriptor = open(url.path, O_EVTONLY)
            guard fileDescriptor >= 0 else { return }
            let src = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fileDescriptor, eventMask: [.write, .extend, .delete, .rename],
                queue: queue)
            src.setEventHandler { [weak self] in self?.drain() }
            src.setCancelHandler { [weak self] in
                guard let self, self.fileDescriptor >= 0 else { return }
                close(self.fileDescriptor)
                self.fileDescriptor = -1
            }
            source = src
            src.resume()
        }
    }

    public func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            handler = nil
        }
    }

    private func drain() {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return }
        if size < offset { offset = 0 }          // ローテーションされた
        guard size > offset else { return }
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
        else { return }
        offset = size

        for line in text.split(separator: "\n") {
            let lower = line.lowercased()
            guard Self.denialMarkers.contains(where: { lower.contains($0) }) else { continue }
            // Finder 自身が作るメタデータファイルの拒否では通知しない
            guard !Self.isSystemMetadataAttempt(String(line)) else { continue }
            // どの read-only マウントに対する失敗かを、マウントパスまたは alias で当てる
            let alias = readOnlyMounts.first { _, path in line.contains(path) }?.key
                ?? readOnlyMounts.keys.first { line.contains($0) }
            handler?(Detection(line: String(line), matchedAlias: alias))
        }
    }
}
