import Foundation

/// ULID（時刻順に並ぶ 26 文字の識別子）。プロファイル ID に使う（§4.2）。
public enum ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    public static func generate(now: Date = Date(),
                               random: () -> UInt8 = { UInt8.random(in: 0...255) }) -> String {
        var chars = [Character]()
        chars.reserveCapacity(26)

        // 上位 10 文字: ミリ秒のタイムスタンプ（48bit）
        var ms = UInt64(max(0, now.timeIntervalSince1970 * 1000))
        var timeChars = [Character]()
        for _ in 0..<10 {
            timeChars.append(alphabet[Int(ms % 32)])
            ms /= 32
        }
        chars.append(contentsOf: timeChars.reversed())

        // 下位 16 文字: 乱数（80bit）
        for _ in 0..<16 {
            chars.append(alphabet[Int(random() % 32)])
        }
        return "prof_" + String(chars)
    }
}

/// rc-user / rc-pass 用の乱数トークン（§6.1）。
/// 起動ごとに生成し、ディスク・ログ・引数のいずれにも出さない（SEC-G01）。
public enum RandomToken {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    public static func make(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        if status != errSecSuccess {
            // SecRandom が失敗する状況では起動を続けるべきではない
            fatalError("SecRandomCopyBytes failed: \(status)")
        }
        return String(bytes.map { alphabet[Int($0) % alphabet.count] })
    }

    /// §4.4: プローブキーに含める乱数（衝突しなければよいので短くてよい）
    public static func probeSuffix() -> String { make(length: 12) }
}
