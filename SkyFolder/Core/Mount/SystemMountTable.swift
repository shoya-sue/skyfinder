import Foundation
import Darwin

/// §8.4 手順 2: OS 側のマウント状態。rcd の `listmounts` では見えない残骸を検出する。
///
/// M-09 が示したとおり、孤児 rcd が保持しているマウントは新しい rcd の `listmounts` に現れない。
/// このとき §02 の DESIGN INVARIANT は成立しないので、OS 側を直接見る手段が要る。
public enum SystemMountTable {

    public struct Entry: Sendable, Equatable {
        public let mountedOn: String
        public let from: String
        public let fsTypeName: String
        /// M-01: read-only マウントでも OS 側には read-only フラグが付かない。
        /// 拒否は rclone の VFS 層で行われるため、この値で G-08 の成否を判定してはならない。
        public let isReadOnlyFlag: Bool
    }

    /// マウント一覧。
    public static func entries() -> [Entry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let base = buffer else { return [] }
        var result: [Entry] = []
        result.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            var s = base[i]
            let on = withUnsafeBytes(of: &s.f_mntonname) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let from = withUnsafeBytes(of: &s.f_mntfromname) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            let type = withUnsafeBytes(of: &s.f_fstypename) { raw -> String in
                String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
            }
            result.append(Entry(mountedOn: on, from: from, fsTypeName: type,
                                isReadOnlyFlag: (s.f_flags & UInt32(MNT_RDONLY)) != 0))
        }
        return result
    }

    /// CAUTION — パス表現の非対称（実測）
    ///
    /// - `mount/mount` と `mount/listmounts` は **渡した表現のまま**返す（`/var/...`）
    /// - OS のマウント表（`getmntinfo` / `mount`）は **シンボリックリンクを解決した**パスを返す
    ///   （`/private/var/...`）
    ///
    /// macOS では `/var` → `/private/var`、`/tmp` → `/private/tmp` が symlink なので、
    /// **OS 側と比較するときだけは解決してから突き合わせる**必要がある。
    /// rclone の応答同士の比較には解決は要らない（表現が保存されるため）。
    public static func resolve(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// OS のマウント表から、このパスに対応する項目を探す。
    /// 表現の違いを吸収するため、両側を解決してから比較する。
    public static func entry(forMountPoint path: String) -> Entry? {
        let target = resolve(path)
        return entries().first { resolve($0.mountedOn) == target }
    }

    /// このパスがマウントポイントか — **ファイルシステムに一切触れずに**判定する。
    ///
    /// `isMountPoint` は `statfs` を使うが、**サーバが死んだ NFS マウントの上では `statfs` 自体がブロックする**
    /// （hard mount なので永久に返らない）。後始末や診断のように「壊れているかもしれないパス」を
    /// 相手にする場面では、カーネルのマウント表（`getmntinfo`）だけを見るこちらを使う。
    ///
    /// symlink の解決もファイルシステムに触れるので、`/private` の付け外しを**文字列として**扱う。
    public static func isMountedAccordingToTable(_ path: String) -> Bool {
        let candidates = Set(textualVariants(path))
        return entries().contains { entry in
            !candidates.isDisjoint(with: Set(textualVariants(entry.mountedOn)))
        }
    }

    /// `/var/...` を `/private/var/...` に寄せた正規形。**ファイルシステムに触れない。**
    public static func resolveTextually(_ path: String) -> String {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        for prefix in ["/var", "/tmp", "/etc"] where p == prefix || p.hasPrefix(prefix + "/") {
            return "/private" + p
        }
        return p
    }

    /// `/var/...` と `/private/var/...` のように、macOS の固定 symlink による表記ゆれを
    /// ファイルシステムに触れずに吸収する。
    public static func textualVariants(_ path: String) -> [String] {
        var p = path
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        var out = [p]
        for prefix in ["/var", "/tmp", "/etc"] {
            if p.hasPrefix(prefix + "/") || p == prefix {
                out.append("/private" + p)
            }
            if p.hasPrefix("/private" + prefix + "/") || p == "/private" + prefix {
                out.append(String(p.dropFirst("/private".count)))
            }
        }
        return out
    }

    /// このパスがマウントポイントか。
    ///
    /// `statfs` はマウントポイント上で `f_mntonname` に自分自身を返す。
    /// `statfs` 自体が symlink を解決するので、比較前に両側を解決する。
    ///
    /// **WARNING — 壊れているかもしれないマウントには使わないこと。**
    /// サーバ（rcd）が死んだ NFS マウントは hard mount なので、その上では
    /// `statfs` が**永久に返らない**。§8.4 手順 2 のように「残骸かもしれないパス」を
    /// 相手にする場面では `isMountedAccordingToTable` を使う。
    public static func isMountPoint(_ path: String) -> Bool {
        let canonical = resolve(path)
        var s = statfs()
        guard statfs(canonical, &s) == 0 else { return false }
        let on = withUnsafeBytes(of: &s.f_mntonname) { raw -> String in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return resolve(on) == canonical
    }

    /// §8.4 手順 2 の例外規定で使う: 自分由来と断定できた残骸をアプリから外す。
    ///
    /// SIGKILL まで進んだ場合はクリーンアップが走らないため、この経路が要る。
    /// これが無いと E-04（手動解除の案内）が出てしまい、
    /// T-G34 の期待「再起動でマウントが正常に復帰する」と矛盾する。
    @discardableResult
    public static func forceUnmount(_ path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/umount")
        process.arguments = ["-f", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
