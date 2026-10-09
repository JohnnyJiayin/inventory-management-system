import Foundation
import Supabase

/// 登录状态。只有一个账号（后台已关闭公开注册），登录后会话保存在钥匙串，
/// 重启 App 自动恢复，直到在设置中退出登录。
@MainActor
final class AuthStore: ObservableObject {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(email: String)
    }

    @Published private(set) var state: State = .loading

    private var listener: Task<Void, Never>?

    init() {
        listener = Task { [weak self] in
            for await (_, session) in supabase.auth.authStateChanges {
                guard let self else { return }
                // 本地保存的会话即使 access token 已过期，SDK 也会用 refresh token 自动续期；
                // 续期失败时会再发出 signedOut 事件。
                if let session {
                    self.state = .signedIn(email: session.user.email ?? "")
                } else {
                    self.state = .signedOut
                }
            }
        }
    }

    deinit { listener?.cancel() }

    func signIn(email: String, password: String) async throws {
        try await supabase.auth.signIn(
            email: email.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    func signOut() async {
        // 断网时服务器端注销会失败，但本地会话仍会被清除
        try? await supabase.auth.signOut(scope: .local)
        state = .signedOut
    }
}
