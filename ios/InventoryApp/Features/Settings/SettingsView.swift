import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var network: NetworkMonitor
    @State private var confirmSignOut = false

    var body: some View {
        Form {
            Section("账号") {
                if case let .signedIn(email) = auth.state {
                    LabeledContent("登录邮箱", value: email)
                }
                Button("退出登录", role: .destructive) { confirmSignOut = true }
            }
            Section("连接") {
                LabeledContent("服务器", value: AppConfig.supabaseURL.host ?? "-")
                LabeledContent("状态") {
                    Text(network.isOnline ? "已连接" : "未连接")
                        .foregroundStyle(network.isOnline ? .green : .red)
                }
            }
            Section("关于") {
                LabeledContent("版本", value: Bundle.main.appVersion)
            }
        }
        .navigationTitle("设置")
        .confirmationDialog("确定退出登录？", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) { Task { await auth.signOut() } }
        } message: {
            Text("退出后需要重新输入邮箱和密码。")
        }
    }
}

extension Bundle {
    var appVersion: String {
        let v = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "-"
        let b = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "-"
        return "\(v) (\(b))"
    }
}
