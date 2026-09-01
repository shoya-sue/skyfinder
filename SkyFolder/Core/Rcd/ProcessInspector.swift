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
        // proc_pidpath が使えない場合のフォールバック（M-09 が実測で使った手段）
        return executablePathFast(pid: pid) ?? psCommand(pid: pid)
    }

    /// `proc_pidpath` だけを使う版。**サブプロセスを起動しない**ので非同期文脈でも安全。
    private static func executablePathFast(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    private static func psCommand(pid: pid_t) -> String? {
        let text = runPSSync(arguments: ["-p", String(pid), "-o", "comm="])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    /// `/bin/ps` を同期実行する。**`waitUntilExit()` はスレッドを止める。**
    /// actor や Task の中からは `runPS`（非同期版）を使うこと。
    private static func runPSSync(arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// `/bin/ps` を**協調スレッドプールの外**で走らせる。
    ///
    /// `Process` の起動と `waitUntilExit()` は同期的にスレッドを止める。
    /// actor（`RcdSupervisor`）の中からそのまま呼ぶと協調スレッドプールの 1 本を占有し、
    /// 他の Task の進行を止める — **M-19 で `Thread.sleep` について是正したのと同じ問題**が
    /// `Process` の側に残っていた。
    private static func runPS(arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: runPSSync(arguments: arguments))
            }
        }
    }

    /// この PID が「自分が起動した rclone」か。実行パスの一致で判定する（§8.6.2 (b)）。
    public static func isOurRclone(pid: pid_t, bundledBinary: URL) -> Bool {
        guard isAlive(pid: pid), let path = executablePath(pid: pid) else { return false }
        return matchesBundledBinary(path, bundledBinary)
    }

    /// `isOurRclone` の非同期版。**actor や Task の中からはこちらを使う。**
    /// `proc_pidpath` で足りるときはサブプロセスを起こさず、駄目なときだけ
    /// `/bin/ps` へ落ちる（その 1 回も協調スレッドプールの外で走らせる）。
    public static func isOurRcloneAsync(pid: pid_t, bundledBinary: URL) async -> Bool {
        guard isAlive(pid: pid) else { return false }
        if let path = executablePathFast(pid: pid) {
            return matchesBundledBinary(path, bundledBinary)
        }
        guard let text = await runPS(arguments: ["-p", String(pid), "-o", "comm="]) else {
            return false
        }
        let path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return false }
        return matchesBundledBinary(path, bundledBinary)
    }

    private static func matchesBundledBinary(_ path: String, _ bundledBinary: URL) -> Bool {
        URL(fileURLWithPath: path).standardizedFileURL.path
            == bundledBinary.standardizedFileURL.path
    }

    /// PID ファイルが無い孤児（書込み失敗・ユーザーによる手動削除）も回収できるようにする
    /// フォールバック。実行パスが同梱バイナリと一致するプロセスだけを拾う
    /// — 他のアプリや、ユーザーが自分で入れた rclone を巻き込まないため。
    /// **注意**: これは同期版で、`/bin/ps` の終了までスレッドを止める。
    /// actor や Task の中からは `findOrphanRclonePIDsAsync` を使うこと。
    public static func findOrphanRclonePIDs(bundledBinary: URL, excluding: Set<pid_t> = []) -> [pid_t] {
        guard let text = runPSSync(arguments: ["-A", "-o", "pid=,comm="]) else { return [] }
        return parseOrphanPIDs(from: text, bundledBinary: bundledBinary, excluding: excluding)
    }

    /// `findOrphanRclonePIDs` の非同期版。**actor や Task の中からはこちらを使う。**
    public static func findOrphanRclonePIDsAsync(bundledBinary: URL,
                                                 excluding: Set<pid_t> = []) async -> [pid_t] {
        guard let text = await runPS(arguments: ["-A", "-o", "pid=,comm="]) else { return [] }
        return parseOrphanPIDs(from: text, bundledBinary: bundledBinary, excluding: excluding)
    }

    private static func parseOrphanPIDs(from text: String, bundledBinary: URL,
                                        excluding: Set<pid_t>) -> [pid_t] {
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
