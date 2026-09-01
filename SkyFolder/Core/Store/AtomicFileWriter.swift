import Foundation

/// §8.6.3: 一時ファイル + rename(2) の原子的置換。
///
/// 途中でクラッシュしても壊れた JSON が残らないようにする。追記はしない — 全体を書き直す。
public enum AtomicFileWriter {

    public static func write(_ data: Data, to url: URL, mode: Int = 0o600) throws {
        let directory = url.deletingLastPathComponent()
        try AppPaths.ensureDirectory(directory, mode: 0o700)

        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")

        // 先に権限つきで作ってから書く（作成と chmod の間に読まれる窓を作らない）
        let fm = FileManager.default
        guard fm.createFile(atPath: temporary.path, contents: nil,
                            attributes: [.posixPermissions: mode]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        do {
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }

        // rename(2) は同一ボリューム内で原子的
        if rename(temporary.path, url.path) != 0 {
            let code = errno
            try? fm.removeItem(at: temporary)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [
                NSLocalizedDescriptionKey: "\(url.lastPathComponent) を置き換えられませんでした"
            ])
        }
        // rename でモードは引き継がれるが、既存ファイルを置換した場合に備えて明示する
        try? fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }
}
