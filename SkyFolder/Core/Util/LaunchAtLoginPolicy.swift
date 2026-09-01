import Foundation
import ServiceManagement

/// §8.5 / U-14: ログイン時起動の冪等な扱い。
///
/// `SMAppService.mainApp.register()` を登録済みの状態で、また `unregister()` を未登録の状態で
/// 再度呼んでも例外にならないかは**未検証**（U-14）。冪等でない場合、
/// 起動のたびに登録を試みる実装がエラーになる。
///
/// 回避（既定の実装方針）: **`status` を先に読み、望む状態と異なるときだけ呼ぶ。**
/// この方針なら `register` / `unregister` 自体の冪等性に依存しない。
///
/// 判定を純粋関数として切り出してあるので、実際に登録せずに検証できる
/// （テストがユーザーのログイン項目を書き換えてしまわないため）。
public enum LaunchAtLoginPolicy {

    public enum RegistrationStatus: Sendable, Equatable {
        case enabled
        case notRegistered
        case requiresApproval
        case notFound
    }

    public enum Action: Sendable, Equatable {
        case register
        case unregister
        case doNothing
    }

    /// 現在の状態と望む状態から、呼ぶべき操作を決める。
    public static func action(current: RegistrationStatus, desired: Bool) -> Action {
        switch (current, desired) {
        case (.enabled, true): return .doNothing
        case (.enabled, false): return .unregister
        // 承認待ちは「登録はされている」状態なので、有効化のために再度呼ばない
        case (.requiresApproval, true): return .doNothing
        case (.requiresApproval, false): return .unregister
        case (_, true): return .register
        case (_, false): return .doNothing
        }
    }

    public static func currentStatus() -> RegistrationStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        case .notRegistered: return .notRegistered
        @unknown default: return .notRegistered
        }
    }

    public static var isEnabled: Bool { currentStatus() == .enabled }

    /// 望む状態にする。すでにその状態なら何もしない（冪等）。
    public static func apply(desired: Bool) throws {
        switch action(current: currentStatus(), desired: desired) {
        case .register: try SMAppService.mainApp.register()
        case .unregister: try SMAppService.mainApp.unregister()
        case .doNothing: break
        }
    }
}
