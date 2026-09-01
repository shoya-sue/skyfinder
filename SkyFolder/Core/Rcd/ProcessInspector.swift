import Foundation
import Darwin

/// §8.6.2 (b): 孤児 rcd の回収に必要なプロセス検査。
///
/// PID の使い回しを踏まないため、PID だけで判断せず **実行パスが同梱バイナリと一致するか**を見る。
public enum ProcessInspector {

    /// プロセスが生きているか。シグナル 0 は「送らずに存在と権限だけ確かめる」。
    public static func isAlive(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM は「居るが自分には送れない」= 生きている
        return errno == EPERM
    }

    /// PID の実行ファイルパス。取れなければ nil。
    public static func executablePath(pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        if length > 0 {
            return String(cString: buffer)
        }
        // proc_pidpath が使えない場合のフォールバック（M-09 が実測で使った手段）
        return psCommand(pid: pid)
    }

    private static func psCommand(pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// この PID が「自分が起動した rclone」か。実行パスの一致で判定する（§8.6.2 (b)）。
    public static func isOurRclone(pid: pid_t, bundledBinary: URL) -> Bool {
        guard isAlive(pid: pid), let path = executablePath(pid: pid) else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == bundledBinary.standardizedFileURL.path
    }

    /// PID ファイルが無い孤児（書込み失敗・ユーザーによる手動削除）も回収できるようにする
    /// フォールバック。実行パスが同梱バイナリと一致するプロセスだけを拾う
    /// — 他のアプリや、ユーザーが自分で入れた rclone を巻き込まないため。
    public static func findOrphanRclonePIDs(bundledBinary: URL, excluding: Set<pid_t> = []) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-A", "-o", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return [] }

        let target = bundledBinary.standardizedFileURL.path
        var result: [pid_t] = []
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " ") else { continue }
            guard let pid = pid_t(trimmed[trimmed.startIndex..<space]) else { continue }
            if excluding.contains(pid) || pid == getpid() { continue }
            let comm = trimmed[trimmed.index(after: space)...].trimmingCharacters(in: .whitespaces)
            if comm == target { result.append(pid) }
        }
        return result
    }

    /// SIGTERM → 猶予 → SIGKILL。
    ///
    /// **孤児に対して RC API を呼んではならない**（実装不能）: rc-user / rc-pass はメモリのみで
    /// 永続化しないため（SEC-G01）、前回インスタンスの認証情報はすでに失われており rc は 401 を返す。
    /// SIGTERM で足りることは実測で確認済み（M-08）— マウント中の rcd に SIGTERM を送ると、
    /// プロセス終了と同時にマウントが自動的に解除される。
    ///
    /// - Returns: SIGKILL まで進んだ場合 true（§8.4 手順 2 の例外規定が要るかの判断に使う）
    ///
    /// **注意**: これは同期版で、最大 `gracePeriod` 秒スレッドを止める。
    /// actor や Task の中から呼ぶと協調スレッドプールを塞ぐため、非同期文脈では
    /// `terminateAsync` を使うこと。
    @discardableResult
    public static func terminate(pid: pid_t,
                                gracePeriod: TimeInterval = 5,
                                pollInterval: TimeInterval = 0.1) -> Bool {
        guard isAlive(pid: pid) else { return false }
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if !isAlive(pid: pid) { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }

        guard isAlive(pid: pid) else { return false }
        kill(pid, SIGKILL)
        // SIGKILL ではクリーンアップが走らないため、マウントが残りうる
        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline, isAlive(pid: pid) {
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return true
    }

    /// `terminate` の非同期版。待機に `Task.sleep` を使うのでスレッドを塞がない。
    ///
    /// アプリ終了時（§8.3）のように非同期文脈から呼ぶ場合はこちらを使う
    /// — `Thread.sleep` を actor 内で回すと協調スレッドプールが枯渇し、
    /// 他の `Task` が進まなくなる。
    @discardableResult
    public static func terminateAsync(pid: pid_t,
                                      gracePeriod: TimeInterval = 5,
                                      pollInterval: TimeInterval = 0.1) async -> Bool {
        guard isAlive(pid: pid) else { return false }
        kill(pid, SIGTERM)

        let deadline = Date().addingTimeInterval(gracePeriod)
        while Date() < deadline {
            if !isAlive(pid: pid) { return false }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }

        guard isAlive(pid: pid) else { return false }
        kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(2)
        while Date() < killDeadline, isAlive(pid: pid) {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        return true
    }
}
