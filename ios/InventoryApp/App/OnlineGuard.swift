import SwiftUI

/// 断网时顶部提示条
struct OfflineBanner: View {
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        if !network.isOnline {
            HStack(spacing: 8) {
                Image(systemName: "wifi.exclamationmark")
                Text(network.status == .noNetwork
                     ? "网络未连接：入库、出库和数据修改已暂停"
                     : "无法连接服务器：入库、出库和数据修改已暂停")
                Spacer()
                Button("重试") { Task { await network.checkServer() } }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color.red)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 写操作按钮在断网时不可点击：`.requiresOnline()`
struct RequiresOnline: ViewModifier {
    @EnvironmentObject private var network: NetworkMonitor

    func body(content: Content) -> some View {
        content.disabled(!network.isOnline)
    }
}

extension View {
    func requiresOnline() -> some View { modifier(RequiresOnline()) }
}
