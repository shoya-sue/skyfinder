import Foundation

/// slug 化の規則。用途が 2 つあり、**規則が違う**ので分けて持つ。
public enum Slug {

    /// V-03b: `displayName` から既定 mountPath を作るときの slug。
    ///
    /// 小文字化 → 空白を `-` に → `[^a-z0-9-]` を除去 → 先頭末尾の `-` を除去 → 32 文字で切り詰め。
    /// 結果が空になった場合（displayName が全て日本語の場合など）は `profile-{idの先頭8文字}` を使う。
    ///
    /// これは**既定値の生成にのみ使う規則**で、ユーザーが mountPath を直接編集すればそちらが優先される。
    public static func profileSlug(displayName: String, profileId: String) -> String {
        var s = displayName.lowercased()
        s = s.map { $0 == " " || $0 == "\u{3000}" || $0 == "\t" ? "-" : $0 }
            .reduce(into: "") { $0.append($1) }
        s = String(s.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") || scalar == "-"
        }.map(Character.init))
        while s.hasPrefix("-") { s.removeFirst() }
        while s.hasSuffix("-") { s.removeLast() }
        if s.count > 32 { s = String(s.prefix(32)) }
        while s.hasSuffix("-") { s.removeLast() }
        if s.isEmpty {
            // `prof_` を含む ULID から、識別に足る先頭 8 文字を取る
            let bare = profileId.hasPrefix("prof_") ? String(profileId.dropFirst(5)) : profileId
            return "profile-" + String(bare.prefix(8)).lowercased()
        }
        return s
    }

    /// §7.3.1: 共有ファイル名の slug（DD-001 §8.2 を逐語継承）。
    ///
    /// 1. 拡張子を分離する
    /// 2. ベース名を小文字化
    /// 3. 空白を `-` に置換
    /// 4. `[^a-z0-9._-]` を除去
    /// 5. **拡張子も小文字化する**（DD-001 F-07 の指摘事項。省略しないこと）
    /// 6. 結果のベース名が空なら `file-{unixtime}`
    ///
    /// 決定的な規則なので、同じファイルを再度公開すれば同じ key・同じ URL になる（§8.6.3）。
    public static func shareSlug(fileName: String, now: Date = Date()) -> (base: String, ext: String) {
        let url = URL(fileURLWithPath: fileName)
        let rawExt = url.pathExtension
        var base = rawExt.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent

        base = base.lowercased()
        base = String(base.map { $0 == " " || $0 == "\u{3000}" || $0 == "\t" ? "-" : $0 })
        base = String(base.unicodeScalars.filter { scalar in
            (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9")
                || scalar == "." || scalar == "_" || scalar == "-"
        }.map(Character.init))

        if base.isEmpty {
            base = "file-\(Int(now.timeIntervalSince1970))"
        }
        // 5. 拡張子も小文字化する
        return (base, rawExt.lowercased())
    }

    /// slug 化した結果のファイル名（`logo-final.png` のような形）
    public static func shareFileName(fileName: String, now: Date = Date()) -> String {
        let (base, ext) = shareSlug(fileName: fileName, now: now)
        return ext.isEmpty ? base : "\(base).\(ext)"
    }
}
