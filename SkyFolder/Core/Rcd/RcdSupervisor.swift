import Foundation

public enum RcdSupervisorError: Error, LocalizedError, Sendable {
    /// E-01: 10 秒以内に待受開始しなかった
    case startupTimedOut(seconds: TimeInterval)
    case launchFailed(String)
    /// E-02: 同梱 rclone が v1.68 未満
    case rcloneTooOld(found: String, required: String)
    case rcloneNotFound(path: String)
    /// E-01: 5 回再起動に失敗
    case restartLimitReached(attempts: Int)

    public var errorDescription: String? {
        switch self {
        case .startupTimedOut(let s):
            return "内部エンジンが \(Int(s)) 秒以内に起動しませんでした。"
        case .launchFailed(let m):
            return "内部エンジンを起動できませんでした: \(m)"
        case .rcloneTooOld(let found, let required):
            return "アプリの内部コンポーネントが古いため動作できません（\(found) / 必要: \(required) 以上）。"
        case .rcloneNotFound(let path):
            return "内部コンポーネントが見つかりません: \(path)"
        case .restartLimitReached(let n):
            return "内部エンジンの再起動に \(n) 回失敗しました。アプリを再起動してください。"
        }
    }
}

/// rcd の稼働状態。UI と診断画面が読む。
public struct RcdStatus: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case stopped
        case starting
        case running
        case restarting(attempt: Int)
        case failed(String)
    }
    public var phase: Phase = .stopped
    public var port: Int?
    public var pid: Int32?
    public var startedAt: Date?
    public var restartCount: Int = 0

    public var isRunning: Bool { if case .running = phase { return true }; return false }
    public var uptime: TimeInterval? { startedAt.map { Date().timeIntervalSince($0) } }

    public init() {}
}

/// §08: 同梱 rclone バイナリの rcd 起動・死活監視・異常終了時の再起動・アプリ終了時の確実な停止。
///
/// 認証情報（rc-user / rc-pass）とポートはプロセス起動ごとに生成する（SEC-G01）。
public actor RcdSupervisor {

    public struct Config: Sendable {
        /// §8.1 手順 4: 10 秒以内に待受開始しなければ E-01
        public var startupTimeout: TimeInterval = 10
        /// §8.2: 指数バックオフ 1s / 2s / 4s / 8s / 16s、5 回で断念
        public var restartBackoff: [TimeInterval] = [1, 2, 4, 8, 16]
        /// §8.6.2 (b): SIGTERM のあと SIGKILL までの猶予
        public var terminationGrace: TimeInterval = 5
        /// 同梱 rclone に要求する最小バージョン（§8.1 手順 3）
        public var minimumRcloneVersion = "1.68"

        public init() {}
    }

    // MARK: - 状態

    private let rcloneURL: URL
    private let paths: AppPaths
    private let pidFile: RcdPidFile
    private let config: Config

    private var process: Process?
    private var endpoint: RcEndpoint?
    private var status = RcdStatus()
    private var stderrBuffer = ""
    private var intentionalStop = false
    private var restartAttempt = 0

    /// 再起動後に呼ばれる。autoMount のバケットを再マウントするために使う（§8.2）。
    private var onRestarted: (@Sendable (RcEndpoint) async -> Void)?
    /// 5 回失敗して断念したときに呼ばれる（E-01 → 診断画面へ誘導）
    private var onGaveUp: (@Sendable (Error) async -> Void)?
    private var statusObserver: (@Sendable (RcdStatus) -> Void)?

    /// 最後に使った起動仕様。再起動時にそのまま使う（rc-user/rc-pass は作り直す）。
    private var lastSpecFactory: (@Sendable () -> RcdLaunchSpec)?

    public init(rcloneURL: URL, paths: AppPaths, config: Config = Config()) {
        self.rcloneURL = rcloneURL
        self.paths = paths
        self.pidFile = RcdPidFile(url: paths.rcdPID)
        self.config = config
    }

    public func setHandlers(onRestarted: (@Sendable (RcEndpoint) async -> Void)? = nil,
                            onGaveUp: (@Sendable (Error) async -> Void)? = nil,
                            statusObserver: (@Sendable (RcdStatus) -> Void)? = nil) {
        self.onRestarted = onRestarted
        self.onGaveUp = onGaveUp
        self.statusObserver = statusObserver
    }

    public func currentStatus() -> RcdStatus { status }
    public func currentEndpoint() -> RcEndpoint? { endpoint }

    private func update(_ mutate: (inout RcdStatus) -> Void) {
        mutate(&status)
        statusObserver?(status)
    }

    // MARK: - §8.1 手順 3: バージョン確認

    public struct RcloneVersionInfo: Sendable {
        public let version: String       // "v1.75.0"
        public let sha256: String?
        public let raw: String
    }

    /// 同梱 rclone を Process で実行して version を取得する（T-G01）。
    public nonisolated func probeVersion() throws -> RcloneVersionInfo {
        guard FileManager.default.isExecutableFile(atPath: rcloneURL.path) else {
            throw RcdSupervisorError.rcloneNotFound(path: rcloneURL.path)
        }
        let process = Process()
        process.executableURL = rcloneURL
        process.arguments = ["version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw RcdSupervisorError.launchFailed(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let version = first.replacingOccurrences(of: "rclone ", with: "")
            .trimmingCharacters(in: .whitespaces)
        return RcloneVersionInfo(version: version, sha256: nil, raw: text)
    }

    /// "v1.75.0" >= "1.68" の比較
    public static func versionAtLeast(_ found: String, _ required: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let f = parts(found), r = parts(required)
        for i in 0..<max(f.count, r.count) {
            let a = i < f.count ? f[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a > b }
        }
        return true
    }

    public func verifyVersion() throws -> RcloneVersionInfo {
        let info = try probeVersion()
        guard Self.versionAtLeast(info.version, config.minimumRcloneVersion) else {
            throw RcdSupervisorError.rcloneTooOld(found: info.version,
                                                  required: config.minimumRcloneVersion)
        }
        return info
    }

    // MARK: - §8.1 手順 0-b: 孤児 rcd の回収（CRIT-03）

    public struct ReclaimResult: Sendable, Equatable {
        /// 回収したプロセスの PID
        public var reclaimedPIDs: [Int32] = []
        /// SIGKILL まで進んだ PID。§8.4 手順 2 の例外規定（自分由来のマウントは umount してよい）が要る。
        public var forceKilledPIDs: [Int32] = []
        public var hadPidFile = false
    }

    /// 前回の孤児プロセスを回収する。**RC API は呼ばない**（呼べない・§8.6.2 (b)）。
    ///
    /// 実行パスを照合して「自分が起動した rclone」と確認できたものだけを止める。
    /// PID の使い回しを踏まないため、PID だけでは判断しない。
    @discardableResult
    public func reclaimOrphans() async -> ReclaimResult {
        var result = ReclaimResult()

        if let record = pidFile.read() {
            result.hadPidFile = true
            let pid = record.pid
            if await ProcessInspector.isOurRcloneAsync(pid: pid, bundledBinary: rcloneURL) {
                let forced = await ProcessInspector.terminateAsync(
                    pid: pid, gracePeriod: config.terminationGrace)
                result.reclaimedPIDs.append(pid)
                if forced { result.forceKilledPIDs.append(pid) }
            }
            pidFile.remove()
        }

        // PID ファイルが無い孤児（書込み失敗・ユーザーによる手動削除）も回収する。
        // 実行パスが同梱バイナリと一致するものだけを対象にして、
        // 他のアプリやユーザー自身の rclone を巻き込まない。
        let already = Set(result.reclaimedPIDs)
        // 非同期版を使う。同期版は `/bin/ps` の終了までスレッドを止めるため、
        // actor の中から呼ぶと協調スレッドプールを塞ぐ（M-19 と同じ問題）。
        for pid in await ProcessInspector.findOrphanRclonePIDsAsync(
            bundledBinary: rcloneURL, excluding: already) {
            let forced = await ProcessInspector.terminateAsync(
                pid: pid, gracePeriod: config.terminationGrace)
            result.reclaimedPIDs.append(pid)
            if forced { result.forceKilledPIDs.append(pid) }
        }
        return result
    }

    // MARK: - 起動

    /// rcd を起動し、待受ポートを取得して RcEndpoint を返す（§8.1 手順 4）。
    @discardableResult
    public func start(specFactory: @escaping @Sendable () -> RcdLaunchSpec) async throws -> RcEndpoint {
        if let existing = endpoint, status.isRunning { return existing }
        lastSpecFactory = specFactory
        intentionalStop = false
        return try await launch(spec: specFactory())
    }

    private func launch(spec incoming: RcdLaunchSpec) async throws -> RcEndpoint {
        // SEC-G01: rc-user / rc-pass は**プロセス起動ごとの乱数**でなければならない。
        // 呼び出し側の specFactory が同じ spec を返しても使い回されないよう、ここで必ず作り直す。
        // 安全性を「呼び出し側が毎回新しい spec を作る」という慣習に依存させない。
        let spec = incoming.regeneratingCredentials()
        update { $0.phase = .starting }

        // ログファイルは追記されるので、起動前のサイズから後ろだけを読む（M-12）
        let logFile = URL(fileURLWithPath: logFilePath(from: spec))
        try AppPaths.ensureDirectory(logFile.deletingLastPathComponent(), mode: 0o700)
        let reader = RcdPortReader(logFile: logFile)

        let process = Process()
        process.executableURL = spec.executableURL
        process.arguments = spec.arguments
        // 環境は spec が持つものだけを渡す（親の環境を丸ごと引き継がない）。
        // PATH だけは rclone が外部コマンドを探す場面のために残す。
        var env = spec.environment
        env["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory()
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stderrBuffer = ""

        // 実測では --log-file 指定時に stderr は空になるが、
        // rclone 側の挙動が変わった場合の保険として拾っておく（M-12）。
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { await self?.appendStderr(text) }
        }
        // stdout は読み捨てるが、閉じないとパイプが詰まる
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in _ = handle.availableData }

        process.terminationHandler = { [weak self] finished in
            Task { await self?.handleTermination(exitCode: finished.terminationStatus) }
        }

        do {
            try process.run()
        } catch {
            update { $0.phase = .failed(error.localizedDescription) }
            throw RcdSupervisorError.launchFailed(error.localizedDescription)
        }

        self.process = process
        update {
            $0.pid = process.processIdentifier
            $0.startedAt = Date()
        }

        let port: Int
        do {
            port = try await reader.wait(timeout: config.startupTimeout,
                                         extraSources: { [weak self] in
                                             // actor 外から同期で読むため、直近の値のコピーを使う
                                             self?.stderrSnapshot ?? ""
                                         })
        } catch {
            // 起動に失敗したプロセスを残さない
            intentionalStop = true
            process.terminate()
            self.process = nil
            update { $0.phase = .failed("起動タイムアウト") }
            throw error
        }

        let ep = RcEndpoint(port: port, user: spec.rcUser, password: spec.rcPassword)
        self.endpoint = ep
        update {
            $0.phase = .running
            $0.port = port
        }

        // §8.6.2 (a): PID とポートを記録する。認証情報は書かない（SEC-G01）。
        try? pidFile.write(RcdPidRecord(pid: process.processIdentifier,
                                        port: port,
                                        executablePath: spec.executableURL.standardizedFileURL.path))
        restartAttempt = 0
        return ep
    }

    private nonisolated var stderrSnapshot: String {
        // actor 隔離を跨がないよう、保険用途に限って空を返す。
        // 実測では --log-file 指定時に stderr は空（M-12）。
        ""
    }

    private func appendStderr(_ text: String) {
        stderrBuffer += text
        if stderrBuffer.count > 64_000 {
            stderrBuffer = String(stderrBuffer.suffix(32_000))
        }
    }

    private func logFilePath(from spec: RcdLaunchSpec) -> String {
        if let i = spec.arguments.firstIndex(of: "--log-file"), i + 1 < spec.arguments.count {
            return spec.arguments[i + 1]
        }
        return paths.logs.appendingPathComponent("rcd.log").path
    }

    // MARK: - §8.2 死活監視と再起動

    private func handleTermination(exitCode: Int32) async {
        process = nil
        endpoint = nil
        if intentionalStop {
            update { $0.phase = .stopped; $0.port = nil; $0.pid = nil }
            return
        }
        await restartWithBackoff()
    }

    private func restartWithBackoff() async {
        guard let factory = lastSpecFactory else {
            update { $0.phase = .stopped }
            return
        }
        while restartAttempt < config.restartBackoff.count {
            let delay = config.restartBackoff[restartAttempt]
            restartAttempt += 1
            update {
                $0.phase = .restarting(attempt: restartAttempt)
                $0.restartCount += 1
            }
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if intentionalStop { return }
            do {
                // rc-user / rc-pass は起動ごとに作り直す（SEC-G01）
                let ep = try await launch(spec: factory())
                await onRestarted?(ep)
                return
            } catch {
                continue
            }
        }
        let error = RcdSupervisorError.restartLimitReached(attempts: config.restartBackoff.count)
        update { $0.phase = .failed(error.errorDescription ?? "再起動に失敗") }
        await onGaveUp?(error)
    }

    // MARK: - §8.3 終了

    /// rcd を確実に止める。呼び出し側は先に mount/unmountall を済ませておくこと（§8.3）。
    /// 2 回呼んでもエラーにしない（冪等）。
    public func stop() async {
        intentionalStop = true
        guard let process, process.isRunning else {
            pidFile.remove()
            update { $0.phase = .stopped; $0.port = nil; $0.pid = nil }
            self.process = nil
            self.endpoint = nil
            return
        }
        let pid = process.processIdentifier
        // actor 内で Thread.sleep を回すと協調スレッドプールを塞ぐため、非同期版を使う
        await ProcessInspector.terminateAsync(pid: pid, gracePeriod: config.terminationGrace)
        self.process = nil
        self.endpoint = nil
        pidFile.remove()   // §8.6.2 (d)
        update { $0.phase = .stopped; $0.port = nil; $0.pid = nil }
    }
}
