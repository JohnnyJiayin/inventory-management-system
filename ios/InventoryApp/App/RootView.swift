import SwiftUI

struct RootView: View {
    @EnvironmentObject private var auth: AuthStore
    @EnvironmentObject private var network: NetworkMonitor

    var body: some View {
        VStack(spacing: 0) {
            OfflineBanner()
            Group {
                switch auth.state {
                case .loading:
                    ProgressView("正在加载…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .signedOut:
                    LoginView()
                case .signedIn:
                    MainView()
                }
            }
        }
        .animation(.default, value: network.isOnline)
    }
}
