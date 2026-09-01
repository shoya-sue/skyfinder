import Foundation

/// SEC-G04: ログに secret・presigned URL・Access Key を出力しない。
///
/// 診断画面でログを表示する際に適用する。マスク対象:
/// - Secret Access Key / Access Key ID（起動時に登録した実値）
/// - rc-pass、および **rc-user**（M-04: rclone は
///   `INFO : Using --user {rc-user} --pass XXXX as authenticated user` を出力し、
///   パスワードはマスクされるが**ユーザー名は平文**で出る）
/// - accountId（M-06: S3 操作の失敗時にエラー本文へ
///   `https://{accountId}.r2.cloudflarestorage.com/...` が含まれる。
///   秘密情報ではないが、診断ログを第三者に共有する場面で意図せず開示される）
/// - presigned URL の署名部分（`X-Amz-Signature` 等）
public struct LogMasker: Sendable {

    public static let placeholder = "***"

    /// 起動ごとに変わる実値。長い順に置換して部分一致で崩れないようにする。
    private let literals: [String]

    private static let signatureQueryKeys = [
        "X-Amz-Signature", "X-Amz-Credential", "X-Amz-Security-Token", "Signature", "AWSAccessKeyId",
    ]

    public init(secrets: [String] = [], accountIds: [String] = [], rcUsers: [String] = []) {
        var all = secrets + rcUsers
        all += accountIds
        self.literals = all
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }          // 短すぎる値で本文が壊れないように
            .sorted { $0.count > $1.count }
    }

    public func mask(_ text: String) -> String {
        var out = text

        // 1. 既知のリテラル（Secret / Access Key / rc-user / rc-pass / accountId）
        for literal in literals {
            out = out.replacingOccurrences(of: literal, with: Self.placeholder)
        }

        // 2. rclone の起動ログに出る rc-user（M-04）。実値を知らない経路でも消す。
        out = Self.maskPattern(out,
                               #"(Using --user )(\S+)"#,
                               template: "$1\(Self.placeholder)")

        // 3. presigned URL の署名部分。URL 自体は残して署名だけ潰す
        //    （診断の役には立つため完全な削除はしない）
        for key in Self.signatureQueryKeys {
            out = Self.maskPattern(out,
                                   "(\(NSRegularExpression.escapedPattern(for: key))=)[^&\\s\"']+",
                                   template: "$1\(Self.placeholder)")
        }

        // 4. accountId 由来の endpoint（M-06）。実値を知らない経路でも消す。
        out = Self.maskPattern(out,
                               #"https://[0-9a-f]{32}\.r2\.cloudflarestorage\.com"#,
                               template: "https://{account-id}.r2.cloudflarestorage.com")

        return out
    }

    /// SEC-G04: ログ行のうち、マスク後もなお秘密が残っていないかの自己検査（T-G27）。
    public func containsSecret(_ text: String) -> Bool {
        for literal in literals where text.contains(literal) { return true }
        return text.contains("X-Amz-Signature=") && !text.contains("X-Amz-Signature=\(Self.placeholder)")
    }

    private static func maskPattern(_ text: String, _ pattern: String, template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        return regex.stringByReplacingMatches(in: text,
                                              range: NSRange(text.startIndex..., in: text),
                                              withTemplate: template)
    }
}
